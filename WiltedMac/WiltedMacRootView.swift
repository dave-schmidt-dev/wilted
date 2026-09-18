import AppKit
import SwiftUI
import WiltedDomain

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
    @State private var playerPresentation: WiltedMacPlayerSection?
    @State private var playerFocusRequest: WiltedMacPlayerSection?

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
            // The unit-test host is the app bundle, so this view is shown
            // there too, and it would open the daily driver's own library
            // under every test run. On 2026-09-05 that closed a live
            // preparation run in the owner's library from inside a test.
            // Tests build their own models and bootstrap those on purpose.
            guard !WiltedMacModel.hostsTests else { return }
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
                        playerFocusRequest = nil
                        model.selectedNavigation = destination
                    } label: {
                        Label(destination.title, symbol: destination.symbolName)
                            .wiltedFont(.body)
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
                Section {
                    sidebarTotal(
                        "Ready to play",
                        summary: model.menuGroupAudioSummary(.playable),
                        identifier: "wilted-sidebar-ready-total"
                    )
                    sidebarTotal(
                        "Downloaded",
                        summary: model.menuGroupAudioSummary(.downloaded),
                        identifier: "wilted-sidebar-downloaded-total"
                    )
                    sidebarTotal(
                        "On the Menu",
                        summary: model.menuAudioSummary,
                        identifier: "wilted-sidebar-menu-total"
                    )
                } header: {
                    Text("Waiting for you")
                }
            }
            // The sidebar carries a page-token background rather than the
            // default AppKit material. It matches the rest of the palette, and
            // the material was additionally invisible to offscreen rendering,
            // which is why the navigation column recorded as a blank rectangle
            // in every Mac pixel baseline.
            .scrollContentBackground(.hidden)
            .background(WiltedTheme.color(.page, scheme: colorScheme))
            .navigationSplitViewColumnWidth(
                min: WiltedTheme.scaled(180, scale: model.textScale),
                ideal: WiltedTheme.scaled(200, scale: model.textScale),
                max: WiltedTheme.scaled(260, scale: model.textScale)
            )
            .navigationTitle("Wilted")
            .accessibilityIdentifier("wilted-mac-sidebar")
        } detail: {
            ZStack {
                VStack(spacing: 0) {
                    Group {
                        switch model.selectedNavigation {
                        case .feeds:
                            WiltedMacFeedsView(model: model)
                        case .menu:
                            WiltedMacMenuView(
                                model: model,
                                presentation: $playerPresentation,
                                focusRequest: playerFocusRequest
                            )
                        case .settings:
                            WiltedMacSettingsView(model: model)
                        }
                    }
                    if playerPresentation == nil && model.selectedNavigation != .menu {
                        Divider()
                        WiltedMacCompactPlayer(
                            model: model,
                            presentation: $playerPresentation,
                            focusRequest: playerFocusRequest
                        )
                    }
                }
                // Keep the selected destination mounted so Collapse returns to
                // the same scroll position, but make its controls unavailable
                // while the full-window player is presented. Otherwise the
                // overlay would leave duplicate live controls in the AX tree.
                // Menu owns its compact player in the destination so its
                // transcript and notes expand inline. Other destinations use
                // the full-window presentation below. Treating both states
                // alike hid Menu as soon as its inline control expanded,
                // leaving Escape with no reachable destination to restore.
                .allowsHitTesting(playerPresentation == nil || model.selectedNavigation == .menu)
                .accessibilityHidden(playerPresentation != nil && model.selectedNavigation != .menu)
                .disabled(playerPresentation != nil && model.selectedNavigation != .menu)

                if playerPresentation != nil, model.selectedNavigation != .menu {
                    WiltedMacFullWindowPlayer(
                        model: model,
                        presentation: $playerPresentation,
                        onSelect: { playerPresentation = $0 },
                        onCollapse: { section in
                            playerPresentation = nil
                            playerFocusRequest = section
                        }
                    )
                }
            }
            // The full-window player belongs to the destination that presented
            // it. Every writer of `selectedNavigation` -- the sidebar and the
            // model's own open/restore paths -- retires it here, so no
            // destination change can leave the overlay behind. The collapse
            // callback keeps its own clear above: collapsing is not a
            // navigation change.
            .onChange(of: model.selectedNavigation) {
                playerPresentation = nil
            }
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        // One place the chosen size enters the window. Every typographic
        // site reads it back out through `wiltedFont`.
        .environment(\.wiltedTextScale, model.textScale)
        // And a base font for everything that never named one. A button, a
        // picker and a sidebar row take the platform's default font rather
        // than a theme role, so they are invisible to `wiltedFont` and stayed
        // at 13pt while the text around them grew. At `.standard` this is the
        // same font they were already inheriting, so it changes nothing until
        // the reader asks for a change.
        .font(WiltedTheme.font(.body, scale: model.textScale))
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

    /// One sidebar waiting time. The figure and its unknown count come from
    /// the same summary the matching Menu heading counts, so the two surfaces
    /// cannot disagree, and an unknown duration is shown as a count rather
    /// than silently summed as zero.
    private func sidebarTotal(
        _ label: String, summary: WiltedMacQueueAudioSummary, identifier: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            Spacer()
            Text(summary.detailLabel)
                .wiltedFont(.utility)
                .monospacedDigit()
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var startupLoading: some View {
        VStack(spacing: WiltedTheme.Spacing.medium) {
            // The current bootstrap phase, not one fixed sentence: a store
            // migration that takes a while should say which wait this is.
            ProgressView(model.startupStepLabel)
                .accessibilityLabel(model.startupStepLabel)
            Text("Your saved library stays in place while Wilted checks its format.")
                .wiltedFont(.body)
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
                .wiltedFont(.display)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Text(failure.message)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            if let detail = failure.detail {
                Text(detail)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("wilted-mac-startup-error-detail")
            }
            if let retainedURL = failure.retainedV5StoreURL {
                Text("A retained V5 recovery copy is available at:")
                    .wiltedFont(.body)
                Text(retainedURL.path)
                    .wiltedFont(.utility)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("wilted-mac-retained-v5-location")
                Button("Show Recovery Copy in Finder") {
                    model.presentRetainedV5Store()
                }
                .accessibilityIdentifier("wilted-mac-show-retained-v5")
            }
            if failure.canRetry {
                Button("Retry Opening Your Library") {
                    model.retryStoreBootstrap()
                }
                .accessibilityIdentifier("wilted-mac-startup-retry")
            } else {
                Text("Retry limit reached. Keep the recovery copy and relaunch Wilted before trying again.")
                    .wiltedFont(.utility)
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
                    .wiltedFont(.display)
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

/// The offer to follow a feed an added page advertises.
private struct WiltedMacAdvertisedFeedOffer: View {
    let model: WiltedMacModel
    let feedURL: URL
    let identifier: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            Text("That page publishes a feed at \(feedURL.host ?? feedURL.absoluteString).")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Subscribe") { model.subscribeToAdvertisedFeed() }
                .accessibilityIdentifier("\(identifier)-subscribe")
            Button("Not Now") { model.dismissAdvertisedFeed() }
                .accessibilityIdentifier("\(identifier)-dismiss")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Feeds

/// Subscribing, and feed upkeep, on one page.
///
/// Subscribing used to happen in Larder's single add box, which asked the
/// listener to paste a feed into a control labelled for articles. This page now
/// owns the decision: its composer takes the feed, and the list below is what
/// the app does with it once followed -- refresh it, hide it, or drop it.
private struct WiltedMacFeedsView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    init(model: WiltedMacModel) {
        _model = Bindable(model)
    }

    var body: some View {
        WiltedMacDestination(title: WiltedScreenCopy.feeds, identifier: "wilted-mac-feeds-detail") {
            Text("New episodes from your subscriptions. One decision only: keep it or skip it. Downloading, preparing and playing all happen on the Menu.")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            addFeedControl
            inbox
            restorableEpisodes
            feedManagement
        }
    }

    /// Reversing the one decision Feeds owns lives here: a skipped row
    /// (retired, records intact) restores without touching the network, while a
    /// removed row still checks its feed because removal deleted its records.
    @ViewBuilder private var restorableEpisodes: some View {
        if !model.skippedFeedEpisodes.isEmpty || !model.dismissedEpisodes.isEmpty {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                Text("Off the list")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
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
                Text("Nothing new. Every episode from your feeds is already waiting on the Menu.")
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feeds-empty")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.feedsEpisodes.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 { Divider() }
                        feedsEpisodeRow(episode)
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

    /// One inbox row. The buttons are the enum, in declaration order, so the
    /// row cannot grow a third action without changing the one list the tests
    /// read.
    private func feedsEpisodeRow(_ episode: WiltedMacEpisode) -> some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                Text("\(episode.feedTitle) · \(episode.lifecyclePresentation.primaryLabel)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(WiltedMacFeedsAction.allCases) { action in
                Button(action.rawValue) {
                    switch action {
                    case .keep: model.keepEpisode(episode)
                    case .skip: model.skipFeedEpisode(episode)
                    }
                }
                .accessibilityLabel("\(action.rawValue) \(episode.title)")
                .accessibilityIdentifier("wilted-feeds-\(action.rawValue.lowercased())-\(episode.id)")
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feeds-row-\(episode.id)")
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

    /// Refresh belongs to the list it refreshes. On its own card it was one
    /// button in a wide empty band, the same defect the Larder order control
    /// had before it moved into the list header.
    private var refreshHeader: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            // Not "Podcast feeds" again: that is the page's own heading now.
            Text("Subscriptions")
                .wiltedFont(.title)
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

/// Keeps the transient podcast status row at a two-line minimum without
/// truncating a longer diagnostic message.
enum WiltedMacPodcastOperationMessageLayout {
    static let utilityLineHeight: CGFloat = 16
    static let reservedLineCount = 2

    static func minimumRowHeight(for scale: WiltedTheme.TextScale) -> CGFloat {
        WiltedTheme.scaled(utilityLineHeight * CGFloat(reservedLineCount), scale: scale)
    }

    static func rowHeight(for measuredTextHeight: CGFloat, scale: WiltedTheme.TextScale) -> CGFloat {
        max(minimumRowHeight(for: scale), measuredTextHeight)
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
    @Environment(\.wiltedTextScale) private var textScale

    var body: some View {
        if let message = model.podcastOperationMessage {
            HStack(spacing: WiltedTheme.Spacing.small) {
                Text(message)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        minHeight: WiltedMacPodcastOperationMessageLayout.minimumRowHeight(for: textScale),
                        alignment: .top
                    )
                    .accessibilityIdentifier("wilted-podcast-operation-message")
                if let undoable = model.undoableRemoval {
                    Button("Undo") {
                        model.restoreEpisode(undoable)
                    }
                    .accessibilityIdentifier("wilted-podcast-undo-removal")
                    .accessibilityLabel("Undo removing \(undoable.title)")
                }
                if let skipped = model.undoableSkip {
                    // The reversible Skip: nothing was deleted, so this is a
                    // local restore that works with no network.
                    Button("Undo Skip") {
                        model.undoSkipEpisode(skipped)
                    }
                    .accessibilityIdentifier("wilted-podcast-undo-skip")
                    .accessibilityLabel("Undo skipping \(skipped.title)")
                }
            }
        }
    }
}

/// A tokenized field border replaces macOS's system-blue focus treatment.
struct WiltedMacLinkField: View {
    @Binding var text: String
    let placeholder: String
    /// Each composer names its own field: two fields sharing one identifier is
    /// an ambiguous query the moment both are reachable.
    let identifier: String
    let focusedOverride: Bool?
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(
        text: Binding<String>,
        placeholder: String = "https://example.com/article",
        identifier: String = "wilted-link-url",
        focusedOverride: Bool? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.identifier = identifier
        self.focusedOverride = focusedOverride
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .wiltedFont(.body)
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
            .accessibilityIdentifier(identifier)
    }
}

/// Show notes, wherever they are read.
///
/// The player and the Larder row render the same feed text, so the URL pass
/// lives apart from either rather than in whichever surface asked first.
enum WiltedShowNotes {
    /// Feed notes arrive as plain text with the URLs written out; make each
    /// one a link so a sponsor code or guest site is a click, not a copy.
    static func linked(_ notes: String) -> AttributedString {
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
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Source and length on one line. Three stacked lines and a
                // card each meant four articles filled the window; a library
                // is a list to scan, not a page to read.
                Text(metaLine)
                    .wiltedFont(.utility)
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
// MARK: - Menu

/// The one place episodes wait: the retired Larder and Menu were the same
/// idea twice. Rows read in a fixed order -- Ready, Downloaded, Available --
/// because an episode can be downloaded, then prepared, then played, and the
/// list says which step is next. Filters and bulk actions read through the
/// same group accessor the rows do, so no count can label a list it does not
/// match.
private struct WiltedMacMenuView: View {
    @Bindable var model: WiltedMacModel
    @Binding var presentation: WiltedMacPlayerSection?
    let focusRequest: WiltedMacPlayerSection?
    @Environment(\.colorScheme) private var colorScheme
    @State private var dropTargetID: String?

    var body: some View {
        WiltedMacDestination(title: "Menu", identifier: "wilted-mac-menu-detail") {
            Text("Everything you kept, in the order you will hear it. Ready plays now; Downloaded needs preparing; Available needs downloading.")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                Text("Now Playing")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                WiltedMacCompactPlayer(
                    model: model,
                    presentation: $presentation,
                    focusRequest: focusRequest
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.medium) {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                    Text("Audio on Menu: \(model.menuAudioSummary.detailLabel)")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-menu-audio-total")
                    Text("Waiting for you: \(model.menuWaitingEpisodes.count) episodes")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-menu-waiting-count")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("Sort", selection: $model.menuSort) {
                    ForEach(Array(WiltedMacMenuSort.allCases), id: \.id) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .accessibilityIdentifier("wilted-menu-sort")
            }

            filterBar
            groupList

            if !model.menuSearchArticleResults.isEmpty {
                articlesSection
            }
        }
        .searchable(text: $model.librarySearchQuery,
                    prompt: "Search titles, shows, notes, and transcripts")
    }

    /// The group filter chips, each carrying the count of the rows it jumps
    /// to. "All waiting" is the unfiltered selection when no search is active;
    /// under a search it is the matching set, so the count and the rows agree.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            HStack(spacing: WiltedTheme.Spacing.small) {
                filterChip(nil, label: "All waiting", count: model.menuSearchResults.count)
                ForEach(WiltedMacMenuGroup.allCases) { group in
                    filterChip(group, label: group.rawValue, count: model.menuEpisodes(in: group).count)
                }
                Spacer()
                Button("Download all new (\(model.menuDownloadableEpisodes.count))") {
                    model.downloadAllAvailableMenuEpisodes()
                }
                .disabled(model.menuDownloadableEpisodes.isEmpty || model.isSearchingMenu)
                .accessibilityIdentifier("wilted-menu-download-all")
                Button("Prepare all downloaded (\(model.menuPreparableEpisodes.count))") {
                    model.prepareAllDownloadedMenuEpisodes()
                }
                .disabled(model.menuPreparableEpisodes.isEmpty || model.isSearchingMenu)
                .accessibilityIdentifier("wilted-menu-prepare-all")
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

    /// A group's own bulk action and its clear.
    ///
    /// The bulk button carries the count of the subset it can act on, and the
    /// clear names what it will do: "Clear all" once any row has been started,
    /// "Skip all" only when every row will simply be passed on.
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
            Button("Prepare all \(model.menuPreparableEpisodes.count)") {
                model.prepareAllDownloadedMenuEpisodes()
            }
            .disabled(model.menuPreparableEpisodes.isEmpty || model.isSearchingMenu)
            .accessibilityIdentifier("wilted-menu-group-prepare-all")
        case .available:
            Button("Download all \(model.menuDownloadableEpisodes.count)") {
                model.downloadAllAvailableMenuEpisodes()
            }
            .disabled(model.menuDownloadableEpisodes.isEmpty || model.isSearchingMenu)
            .accessibilityIdentifier("wilted-menu-group-download-all")
        }
        Button(model.menuGroupClearLabel(group)) {
            model.clearMenuGroup(group)
        }
        .disabled(model.isSearchingMenu)
        .accessibilityLabel("\(model.menuGroupClearLabel(group)) in \(group.rawValue)")
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

    /// The three groups in their fixed order. A group with no rows is not
    /// given an empty heading, and every heading's count comes from
    /// `menuEpisodes(in:)` -- the same call that produces its rows.
    @ViewBuilder private var groupList: some View {
        let groups = model.menuFilter.map { [$0] } ?? WiltedMacMenuGroup.allCases
        let total = model.menuWaitingEpisodes.count
        if model.menuFilteredEpisodes.isEmpty {
            Text(model.isSearchingMenu
                 ? (model.isSearchingTranscripts ? "Still reading transcripts…" : "No episodes match this search.")
                 : (model.menuWaitingEpisodes.isEmpty
                    ? "Nothing is waiting on the Menu. Keep an episode from Feeds."
                    : "No episode is in this group right now."))
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-menu-empty")
        } else {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                ForEach(groups) { group in
                    let episodes = model.menuEpisodes(in: group)
                    if !episodes.isEmpty {
                        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(group.rawValue)
                                    .wiltedFont(.title)
                                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                                Text("\(episodes.count)")
                                    .wiltedFont(.utility)
                                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                    .accessibilityIdentifier("wilted-menu-\(group.rawValue.lowercased())-count")
                                Spacer()
                                Text(group.detail)
                                    .wiltedFont(.utility)
                                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                groupActions(group)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                                    if index > 0 { Divider() }
                                    let position = (model.menuWaitingEpisodes.firstIndex(of: episode) ?? index) + 1
                                    menuRow(episode, position: position, count: total)
                                }
                            }
                            .wiltedCard(colorScheme)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("wilted-menu-group-\(group.rawValue.lowercased())")
                    }
                }
                tailDropTarget
            }
        }
    }

    /// The strip below the last row is a real destination: a drop here appends
    /// the dragged entry. A payload that is not one of the Menu's episodes is
    /// refused and the order left alone.
    private var tailDropTarget: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Image(systemName: "arrow.down.to.line")
                .accessibilityHidden(true)
            Text("Drop here to move to the end")
        }
        .wiltedFont(.utility)
        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(
            dropTargetID == Self.tailDropTargetID
                ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
        )
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
    private var articlesSection: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack {
                Text("Articles")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer()
                addArticleButton
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.menuSearchArticleResults.enumerated()), id: \.element.id) { index, article in
                    if index > 0 { Divider() }
                    WiltedMacArticleRow(model: model, article: article)
                }
            }
            .wiltedCard(colorScheme)
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

    private func menuRow(_ episode: WiltedMacEpisode, position: Int, count: Int) -> some View {
        let group = WiltedMacModel.menuGroup(for: episode)
        return HStack(spacing: WiltedTheme.Spacing.medium) {
            Text(String(format: "%02d", position))
                .wiltedFont(.utility)
                .monospacedDigit()
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                Text("\(episode.feedTitle) · \(group.rawValue)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
                // Preparing stays in Downloaded, and this is the figure that
                // says so; the row does not move groups while it runs.
                if episode.preparationState.isRunning,
                   let fraction = model.preparationFraction(forEpisode: episode.id) {
                    ProgressView(value: fraction)
                        .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                        .frame(width: 120)
                        .accessibilityValue("\(Int(fraction * 100)) percent prepared")
                        .accessibilityIdentifier("wilted-menu-progress-\(episode.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "circle.grid.2x3.fill")
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .draggable(episode.id)
                .help("Drag to reorder")
                .accessibilityLabel("Reorder \(episode.title)")
                .accessibilityAction(named: Text("Move earlier")) {
                    model.moveMenuEpisode(episode.id, by: -1)
                }
                .accessibilityAction(named: Text("Move later")) {
                    model.moveMenuEpisode(episode.id, by: 1)
                }
            nextStepControl(episode, group: group)
            // One retirement control per row. Skip is the reversible one and
            // keeps the media; the destructive path gets no row surface. The
            // label reports the model's one started predicate, so the reader
            // is told whether this finishes a record or just passes the
            // episode on. An unstarted episode stays enabled on purpose:
            // pressing it explains that there was nothing to skip.
            let retirementLabel = model.menuRowRetirementLabel(episode)
            Button(retirementLabel) { model.skipEpisode(episode) }
                .accessibilityLabel("\(retirementLabel) \(episode.title)")
                .accessibilityIdentifier("wilted-menu-skip-\(episode.id)")
            // Remove and Skip/Completed are different acts. Remove takes the
            // entry off the durable queue and leaves every record, the media
            // and the listening state exactly where they are, so the episode
            // returns to Feeds; Skip retires it. The two get separate slots
            // on purpose.
            Button("Remove") { model.removeEpisodeFromUpNext(episode.id) }
                .accessibilityLabel("Remove \(episode.title) from Menu")
                .accessibilityIdentifier("wilted-menu-remove-\(episode.id)")
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .background(
            dropTargetID == episode.id
                ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.12)
                : Color.clear
        )
        .dropDestination(for: String.self) { draggedIDs, _ in
            guard let draggedID = draggedIDs.first else { return false }
            return model.moveMenuEpisode(draggedID, before: episode.id)
        } isTargeted: { targeted in
            dropTargetID = targeted ? episode.id : nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(episode.title), number \(position) on Menu")
        .accessibilityValue("\(position) of \(count)")
        .accessibilityIdentifier("wilted-menu-row-\(episode.id)")
    }

    /// The single step the row is waiting for. Its group already says which
    /// one it is, so a row never shows the other two greyed out.
    @ViewBuilder private func nextStepControl(_ episode: WiltedMacEpisode, group: WiltedMacMenuGroup) -> some View {
        switch group {
        case .playable:
            if model.currentPodcastEpisodeID == episode.id {
                Text(model.isPlaying ? "Playing now" : "Now Playing")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            } else if model.isEpisodeFinished(episode) {
                // The one definition of finished, asked by the row: a finished
                // episode is not waiting to be played again.
                Text("Played")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-menu-played-\(episode.id)")
            } else {
                Button("Play now") { model.playEpisode(episode) }
                    .accessibilityLabel("Play \(episode.title) now")
                    .accessibilityIdentifier("wilted-menu-play-\(episode.id)")
            }
        case .downloaded:
            if episode.preparationState.isRunning {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Text("Preparing…")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    Button("Stop") { model.cancelEpisodePreparation(episode) }
                        .accessibilityLabel("Stop preparing \(episode.title)")
                        .accessibilityIdentifier("wilted-menu-stop-\(episode.id)")
                }
            } else if case .failed = episode.preparationState {
                Button("Retry") { model.prepareEpisode(episode) }
                    .accessibilityLabel("Retry preparing \(episode.title)")
                    .accessibilityIdentifier("wilted-menu-retry-\(episode.id)")
            } else {
                Button("Prepare") { model.prepareEpisode(episode) }
                    .accessibilityIdentifier("wilted-menu-prepare-\(episode.id)")
            }
        case .available:
            switch episode.downloadState {
            case .queued, .downloading:
                Button("Cancel") { model.cancelEpisodeDownload(episode) }
                    .accessibilityIdentifier("wilted-menu-cancel-\(episode.id)")
            case .failed, .cancelled:
                Button("Retry") { model.retryEpisodeDownload(episode) }
                    .accessibilityIdentifier("wilted-menu-retry-\(episode.id)")
            case .notDownloaded, .completed:
                Button("Download") { model.downloadEpisode(episode) }
                    .accessibilityIdentifier("wilted-menu-download-\(episode.id)")
            }
        }
    }

    /// The way in to the address box, moved here with the Larder's remaining
    /// jobs: an article is saved listening, and the Menu is where listening
    /// starts now.
    private var addArticleButton: some View {
        Button {
            model.isPresentingComposer = true
        } label: {
            Label(WiltedScreenCopy.addLink, systemImage: "plus")
        }
        .accessibilityIdentifier("wilted-add-article-button")
        .popover(isPresented: $model.isPresentingComposer, arrowEdge: .bottom) {
            composer
                .frame(width: 420)
                .padding(WiltedTheme.Spacing.large)
                .background(WiltedTheme.color(.card, scheme: colorScheme))
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(WiltedScreenCopy.addLinkTitle)
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Text(WiltedScreenCopy.addLinkDetail)
                .wiltedFont(.body)
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
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-link-status")
            }
            if let advertised = model.advertisedFeed {
                WiltedMacAdvertisedFeedOffer(
                    model: model, feedURL: advertised, identifier: "wilted-advertised-feed"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-mac-composer")
    }
}

// MARK: - Persistent Player
/// A fixed footer outside every destination's scroll view. It keeps playback
/// visible while the Larder moves and owns the complete local podcast surface.
enum WiltedMacPlayerSection: String, Hashable, CaseIterable {
    case transcript
    case notes

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .notes: "Notes"
        }
    }

    var expandedAccessibilityIdentifier: String {
        switch self {
        case .transcript: "wilted-player-transcript-expanded"
        case .notes: "wilted-player-notes-expanded"
        }
    }
}

private enum WiltedMacPlayerLayout: Equatable {
    case rail
    case fullWindow
}

struct WiltedMacCompactPlayer: View {
    @Bindable var model: WiltedMacModel
    @Binding private var presentation: WiltedMacPlayerSection?
    private let focusRequest: WiltedMacPlayerSection?

    init(model: WiltedMacModel) {
        self.model = model
        _presentation = .constant(nil)
        focusRequest = nil
    }

    init(
        model: WiltedMacModel,
        presentation: Binding<WiltedMacPlayerSection?>,
        focusRequest: WiltedMacPlayerSection?
    ) {
        self.model = model
        _presentation = presentation
        self.focusRequest = focusRequest
    }

    var body: some View {
        WiltedMacPlayerContent(
            model: model,
            presentation: $presentation,
            layout: .rail,
            focusRequest: focusRequest,
            onCollapse: { _ in }
        )
        .padding(.horizontal, WiltedTheme.Spacing.medium)
        .padding(.vertical, WiltedTheme.Spacing.small)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback rail")
        .accessibilityValue(presentation == nil ? "Collapsed" : "Expanded")
        .accessibilityIdentifier("wilted-compact-player")
    }

    @Environment(\.colorScheme) private var colorScheme

}

/// A presentation layer over the selected work destination, not a destination
/// itself. The root retains its selected navigation and model while this fills
/// the detail column, so collapsing returns to precisely the prior work view.
struct WiltedMacFullWindowPlayer: View {
    @Bindable var model: WiltedMacModel
    @Binding private var presentation: WiltedMacPlayerSection?
    let onSelect: (WiltedMacPlayerSection) -> Void
    let onCollapse: (WiltedMacPlayerSection) -> Void

    init(
        model: WiltedMacModel,
        presentation: Binding<WiltedMacPlayerSection?>,
        onSelect: @escaping (WiltedMacPlayerSection) -> Void,
        onCollapse: @escaping (WiltedMacPlayerSection) -> Void
    ) {
        self.model = model
        _presentation = presentation
        self.onSelect = onSelect
        self.onCollapse = onCollapse
    }

    var body: some View {
        WiltedMacPlayerContent(
            model: model,
            presentation: $presentation,
            layout: .fullWindow,
            focusRequest: nil,
            onCollapse: onCollapse,
            onSelect: onSelect
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(WiltedTheme.Spacing.section)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-player-full-window")
    }

    @Environment(\.colorScheme) private var colorScheme
}

/// The rail and full-window presentation deliberately delegate here. It owns
/// every transport, label, identifier, enabled state, and selected pane, so a
/// visual change cannot give either form of Now Playing a different player.
private struct WiltedMacPlayerContent: View {

    @Bindable var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding private var presentation: WiltedMacPlayerSection?
    private let layout: WiltedMacPlayerLayout
    private let focusRequest: WiltedMacPlayerSection?
    private let onCollapse: (WiltedMacPlayerSection) -> Void
    private let onSelect: (WiltedMacPlayerSection) -> Void
    @FocusState private var primaryTransportFocused: Bool
    @FocusState private var keyboardFocus: WiltedMacPlayerSection?
    @AccessibilityFocusState private var accessibilityFocus: WiltedMacPlayerSection?

    init(
        model: WiltedMacModel,
        presentation: Binding<WiltedMacPlayerSection?>,
        layout: WiltedMacPlayerLayout,
        focusRequest: WiltedMacPlayerSection?,
        onCollapse: @escaping (WiltedMacPlayerSection) -> Void,
        onSelect: @escaping (WiltedMacPlayerSection) -> Void = { _ in }
    ) {
        self.model = model
        _presentation = presentation
        self.layout = layout
        self.focusRequest = focusRequest
        self.onCollapse = onCollapse
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: WiltedTheme.Spacing.small) {
            if layout == .fullWindow {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Now Playing")
                            .wiltedFont(.display)
                        Text(presentation?.title ?? "")
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    }
                    Spacer()
                    Button("Collapse") { collapsePresentation() }
                        .accessibilityIdentifier("wilted-player-collapse")
                }
            }
            if model.hasCurrentPlayback {
                HStack(spacing: WiltedTheme.Spacing.medium) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                        .wiltedFont(.body)
                        .accessibilityIdentifier("wilted-player-item-title")
                    Text(detail)
                        .lineLimit(1)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityLabel(detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Label hidden and width unconstrained: with both, an 82pt
                // picker showed "Speed" and clipped the value to a sliver.
                Picker("Speed", selection: Binding(
                    get: { model.playbackRate }, set: { model.setPlaybackRate($0) }
                )) {
                    ForEach(WiltedMacModel.playbackRateChoices, id: \.self) {
                        Text("\($0, specifier: "%g")×").tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!model.hasCurrentPlayback)
                .accessibilityLabel("Speed")
                .accessibilityIdentifier("wilted-player-speed")

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
                // Beside Restart because they are the same kind of decision
                // about the whole episode rather than about the playhead: one
                // says start over, the other says done with it. The label goes
                // past tense once the press has nothing left to do, which is
                // the only thing on this row that changes, so the press is
                // visible. It follows the retirement rather than the written
                // record: an episode marked finished but still on the shelf
                // still has the half the listener can see left to do.
                Button(model.playbackCompletionIsSettled ? "Completed" : "Mark completed") {
                    model.markCurrentPlaybackCompleted()
                }
                .disabled(!model.hasCurrentPlayback || model.playbackCompletionIsSettled)
                .accessibilityIdentifier("wilted-player-mark-completed")
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
                    .wiltedFont(.utility)

                expansionButton("Transcript", expansion: .transcript, id: "wilted-player-transcript")
                // Show notes belong to episodes; an article has its own text.
                if model.currentEpisode != nil {
                    expansionButton("Notes", expansion: .notes, id: "wilted-player-notes")
                }
                if model.selectedNavigation != .menu {
                    Button("Menu (\(model.menuUpcomingEpisodeIDs.count))") {
                        presentation = nil
                        model.openMenu()
                    }
                        .accessibilityLabel("Open Menu with \(model.menuUpcomingEpisodeIDs.count) episodes")
                        .accessibilityIdentifier("wilted-player-menu")
                }

                if model.audioRouteFault {
                    Button("Recover audio") { model.recoverAudioRoute() }
                        .accessibilityIdentifier("wilted-player-route-recovery")
                }

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

            if model.playbackError != nil {
                // The status is the sole fault sentence. This container keeps
                // the established recovery identifier without rendering it a
                // second time.
                VStack(alignment: .leading, spacing: 0) {
                    playbackStatus
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("wilted-player-recoverable-error")
            } else {
                playbackStatus
            }

            if let presentation {
                Divider()
                expandedContent(presentation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let status = model.playbackOperationStatus {
                Text(status)
                    .wiltedFont(.utility)
                    .accessibilityIdentifier("wilted-player-operation-status")
            }
            } else {
                minimizedIdlePlayer
            }
        }
        .onExitCommand {
            collapsePresentation()
        }
        .task(id: model.hasCurrentPlayback) {
            guard model.hasCurrentPlayback else { return }
            await Task.yield()
            if layout == .rail, presentation == nil, keyboardFocus == nil {
                primaryTransportFocused = true
            }
            while !Task.isCancelled {
                model.refreshPlaybackReadout()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: focusRequest) {
            guard layout == .rail, let focusRequest else { return }
            await Task.yield()
            keyboardFocus = focusRequest
        }
    }

    @ViewBuilder
    private var playbackStatus: some View {
        // The play/pause transport already speaks these two states. Do not
        // create a second visible or accessible status row for them.
        if model.playbackStatusMessage != "Playing",
           model.playbackStatusMessage != "Paused" {
            Text(model.playbackStatusMessage)
                .wiltedFont(.utility)
                .foregroundStyle(model.playbackStatusTone.color(colorScheme))
                .accessibilityIdentifier("wilted-player-status")
        }
    }

    private var minimizedIdlePlayer: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Image(systemName: "play.circle")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing is playing")
                    .wiltedFont(.body)
                Text("Choose an episode or article from the Menu to start playback.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Minimized")
                .wiltedFont(.utility)
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
        expansion target: WiltedMacPlayerSection,
        id: String
    ) -> some View {
        // The same button closes what it opened, and says so: the pane pushes
        // the list up rather than covering it, and nothing else on screen
        // explained how to get the room back.
        //
        // Both titles are laid out, with only one visible, so the control keeps
        // one width across the toggle. Letting it resize left the focus ring
        // drawn at the wider "Hide ..." size after the title had gone back to
        // the short one, and a toggle that changes width under the pointer is
        // the wrong behaviour regardless of the ring.
        Button {
            toggle(target)
        } label: {
            ZStack {
                Text("Hide \(label)").hidden()
                Text(presentation == target ? "Hide \(label)" : label)
            }
        }
        .accessibilityLabel(presentation == target ? "Hide \(label)" : label)
        .focusable()
        .focused($keyboardFocus, equals: target)
        .onKeyPress(.space) {
            toggle(target)
            return .handled
        }
        .onKeyPress(.escape) {
            guard presentation != nil else { return .ignored }
            collapsePresentation()
            return .handled
        }
        .accessibilityFocused($accessibilityFocus, equals: target)
        .accessibilityValue(presentation == target ? "Expanded" : "Collapsed")
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func expandedContent(_ target: WiltedMacPlayerSection) -> some View {
        switch target {
        case .transcript:
            transcriptContent
                .accessibilityIdentifier(target.expandedAccessibilityIdentifier)
        case .notes:
            notesContent
                .accessibilityIdentifier(target.expandedAccessibilityIdentifier)
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
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-now-playing-transcript")
                WiltedSyncedTranscriptView(
                    cues: transcript.cues.map {
                        WiltedTranscriptCueLine(id: $0.id, startSeconds: $0.startSeconds, text: $0.text, speaker: $0.speaker)
                    },
                    markers: model.currentRemovedSpans.map {
                        WiltedTranscriptMarkerLine(id: $0.id, atSeconds: $0.preparedSeconds, text: $0.summary)
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
                        .wiltedFont(.body)
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
                    // Untimed prose has nowhere to put a marker in place, so
                    // the cuts are listed instead of dropped silently.
                    if !model.currentRemovedSpans.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.currentRemovedSpans) { span in
                                Text(span.summary)
                                    .wiltedFont(.utility)
                                    .italic()
                                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                    .accessibilityIdentifier("wilted-now-playing-removed-\(span.id)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("wilted-now-playing-removed-spans")
                    }
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
                            .wiltedFont(.utility)
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
                    .wiltedFont(.title)
                if let notes = model.currentEpisode?.notes {
                    Text(WiltedShowNotes.linked(notes))
                        .wiltedFont(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-player-notes-text")
                } else {
                    Text("This episode's feed did not include show notes.")
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-player-notes-unavailable")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-player-notes-list")
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = model.currentEpisode?.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallbackArtwork
            }
            .wiltedSquare(44)
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

    private func toggle(_ target: WiltedMacPlayerSection) {
        if presentation == target {
            collapsePresentation()
        } else {
            presentation = target
            if layout == .fullWindow {
                onSelect(target)
            }
            primaryTransportFocused = false
            Task { @MainActor in
                await Task.yield()
                keyboardFocus = target
            }
        }
    }

    private func collapsePresentation() {
        guard let presentation else { return }
        if layout == .fullWindow {
            onCollapse(presentation)
        } else {
            self.presentation = nil
        }
    }

    private func transport(
        _ symbol: String,
        label: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .wiltedSquare(28)
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
            appearanceCard
            lifetimeStatisticsCard
            automationCard
            syncCard
        }
    }

    private var lifetimeStatisticsCard: some View {
        WiltedSettingsCard(title: WiltedScreenCopy.lifetimeStatistics) {
            Text(WiltedScreenCopy.lifetimeStatisticsScope)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier(WiltedScreenCopy.lifetimeStatisticsScopeIdentifier)
            Divider()
            WiltedSettingsRow(
                WiltedScreenCopy.audioProcessed,
                value: WiltedDuration.spoken(model.lifetimeStatistics.audioProcessedSeconds),
                identifier: WiltedScreenCopy.audioProcessedIdentifier
            )
            Divider()
            WiltedSettingsRow(
                WiltedScreenCopy.speechGenerated,
                value: WiltedDuration.spoken(model.lifetimeStatistics.speechGeneratedSeconds),
                identifier: WiltedScreenCopy.speechGeneratedIdentifier
            )
            Divider()
            WiltedSettingsRow(
                WiltedScreenCopy.confirmedAdTimeRemoved,
                value: WiltedDuration.spoken(model.lifetimeStatistics.confirmedAdTimeRemovedSeconds),
                identifier: WiltedScreenCopy.confirmedAdTimeRemovedIdentifier
            )
            Divider()
            WiltedSettingsRow(
                WiltedScreenCopy.fasterPlaybackTimeSaved,
                value: WiltedDuration.spoken(model.lifetimeStatistics.fasterPlaybackTimeSavedSeconds),
                identifier: WiltedScreenCopy.fasterPlaybackTimeSavedIdentifier
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-lifetime-statistics")
    }

    /// The Mac inherits no text size from the system the way iPhone does, so
    /// this is the only place the reader can change it.
    private var appearanceCard: some View {
        WiltedSettingsCard(title: "Appearance") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Picker("Text and icon size", selection: Binding(
                    get: { model.textScale },
                    set: { model.setTextScale($0) }
                )) {
                    ForEach(WiltedTheme.TextScale.allCases) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("wilted-text-scale")
                Text("Applies to every screen. Icons and artwork grow with the text.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-appearance-controls")
    }

    /// Automation follows the path an admitted episode actually takes. The
    /// quiet rules make that sequence scannable without introducing another
    /// settings surface or a decorative treatment competing with the cards.
    private var automationCard: some View {
        WiltedSettingsCard(title: "Automation") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                WiltedSettingsRow(
                    "Status",
                    value: model.automationStatus.settingsStatusText,
                    identifier: "wilted-automation-status"
                )
                if model.automationStatus.isCancellable {
                    Button("Stop") { model.cancelAutomation() }
                        .accessibilityIdentifier("wilted-automation-stop")
                }

                Divider()

                automationSectionTitle("Feeds")
                Picker("Refresh feeds", selection: refreshPolicyBinding) {
                    Text(WiltedAutomationRefreshPolicy.manual.settingsControlLabel)
                        .tag(WiltedAutomationRefreshPolicy.manual.settingsControlLabel)
                    Text(WiltedAutomationRefreshPolicy.onLaunch.settingsControlLabel)
                        .tag(WiltedAutomationRefreshPolicy.onLaunch.settingsControlLabel)
                    ForEach([6, 12, 24], id: \.self) { hours in
                        let policy = WiltedAutomationRefreshPolicy.whileOpen(everyHours: hours)
                        Text(policy.settingsControlLabel).tag(policy.settingsControlLabel)
                    }
                }
                .accessibilityIdentifier("wilted-automation-refresh-policy")

                Divider()

                automationSectionTitle("Downloads")
                Picker("Download episodes", selection: downloadPolicyBinding) {
                    ForEach([
                        WiltedAutomationDownloadPolicy.manual,
                        .newestOnePerEnabledFeed,
                        .newestThreePerEnabledFeed,
                        .allNewlyAdmittedUpToTwenty
                    ], id: \.rawValue) { policy in
                        Text(policy.settingsControlLabel).tag(policy.settingsControlLabel)
                    }
                }
                .accessibilityIdentifier("wilted-automation-download-policy")

                Divider()

                automationSectionTitle("Processing")
                Picker("Prepare episodes", selection: processingPolicyBinding) {
                    Text(WiltedAutomationProcessingPolicy.immediate.settingsControlLabel)
                        .tag(WiltedAutomationProcessingPolicy.immediate.settingsControlLabel)
                    Text(WiltedAutomationProcessingPolicy.manual.settingsControlLabel)
                        .tag(WiltedAutomationProcessingPolicy.manual.settingsControlLabel)
                    Text(WiltedAutomationProcessingPolicy.offPeak(defaultOffPeakWindow).settingsControlLabel)
                        .tag(WiltedAutomationProcessingPolicy.offPeak(defaultOffPeakWindow).settingsControlLabel)
                }
                .accessibilityIdentifier("wilted-automation-processing-policy")

                if isOffPeakProcessing {
                    DatePicker("Start", selection: offPeakStartBinding, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("wilted-automation-off-peak-start")
                    DatePicker("End", selection: offPeakEndBinding, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("wilted-automation-off-peak-end")
                    Text("Uses local time. The window may continue overnight.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-automation-off-peak-explanation")
                }

                Divider()

                automationSectionTitle("Transcript")
                Picker("Transcript source", selection: transcriptPolicyBinding) {
                    ForEach([
                        WiltedAutomationTranscriptPolicy.bestAvailable,
                        .alwaysTranscribe,
                        .noLocalSTT
                    ], id: \.rawValue) { policy in
                        Text(policy.settingsControlLabel).tag(policy.settingsControlLabel)
                    }
                }
                .accessibilityIdentifier("wilted-automation-transcript-policy")
                Toggle("Remove ads", isOn: removeAdsBinding)
                    .accessibilityIdentifier("wilted-automation-remove-ads")
                if model.automationSettings.transcriptPolicyBlocksAdRemoval {
                    Text(WiltedAutomationSettings.transcriptPolicyBlocksAdRemovalExplanation)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-automation-transcript-conflict")
                }

                Divider()

                automationSectionTitle("Menu")
                Toggle("Add prepared episodes to Menu", isOn: autoAddPreparedToMenuBinding)
                    .accessibilityIdentifier("wilted-automation-auto-add-to-menu")
                Text("An episode joins the Menu when it finishes preparing. Episodes already "
                     + "played, already queued, or now playing are left alone.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-automation-auto-add-to-menu-explanation")
                Toggle("Download everything on the Menu", isOn: downloadEverythingBinding)
                    .accessibilityIdentifier("wilted-automation-download-everything")
                Toggle("Prepare everything downloaded", isOn: prepareEverythingBinding)
                    .accessibilityIdentifier("wilted-automation-prepare-everything")
                Text("Both overrides stay on until you turn them off, and each takes the same "
                     + "step the matching Menu group action takes. Downloads cost disk and "
                     + "bandwidth; preparing spends the machine's speech and detection models.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-automation-menu-overrides-explanation")

            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-automation-controls")
    }

    private func automationSectionTitle(_ title: String) -> some View {
        Text(title)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
    }

    private var refreshPolicyBinding: Binding<String> {
        Binding(
            get: { model.automationSettings.refreshPolicy.settingsControlLabel },
            set: { label in
                guard let policy = WiltedAutomationRefreshPolicy.fromSettingsControlLabel(label) else { return }
                replaceAutomationSettings(refreshPolicy: policy)
            }
        )
    }

    private var downloadPolicyBinding: Binding<String> {
        Binding(
            get: { model.automationSettings.downloadPolicy.settingsControlLabel },
            set: { label in
                guard let policy = WiltedAutomationDownloadPolicy.fromSettingsControlLabel(label) else { return }
                replaceAutomationSettings(downloadPolicy: policy)
            }
        )
    }

    private var processingPolicyBinding: Binding<String> {
        Binding(
            get: { model.automationSettings.processingPolicy.settingsControlLabel },
            set: { label in
                guard let policy = WiltedAutomationProcessingPolicy.fromSettingsControlLabel(
                    label, window: selectedOffPeakWindow
                ) else { return }
                replaceAutomationSettings(processingPolicy: policy)
            }
        )
    }

    private var transcriptPolicyBinding: Binding<String> {
        Binding(
            get: { model.automationSettings.transcriptPolicy.settingsControlLabel },
            set: { label in
                guard let policy = WiltedAutomationTranscriptPolicy.fromSettingsControlLabel(label) else { return }
                replaceAutomationSettings(transcriptPolicy: policy)
            }
        )
    }

    private var removeAdsBinding: Binding<Bool> {
        Binding(get: { model.automationSettings.removeAds }, set: { replaceAutomationSettings(removeAds: $0) })
    }

    private var autoAddPreparedToMenuBinding: Binding<Bool> {
        Binding(get: { model.automationSettings.autoAddPreparedToMenu },
                set: { replaceAutomationSettings(autoAddPreparedToMenu: $0) })
    }

    private var downloadEverythingBinding: Binding<Bool> {
        Binding(get: { model.automationSettings.downloadEverythingOnMenu },
                set: { replaceAutomationSettings(downloadEverythingOnMenu: $0) })
    }

    private var prepareEverythingBinding: Binding<Bool> {
        Binding(get: { model.automationSettings.prepareEverythingDownloaded },
                set: { replaceAutomationSettings(prepareEverythingDownloaded: $0) })
    }

    private var defaultOffPeakWindow: WiltedAutomationOffPeakWindow {
        let start = WiltedAutomationLocalTime(hour: 22, minute: 0)!
        let end = WiltedAutomationLocalTime(hour: 6, minute: 0)!
        return WiltedAutomationOffPeakWindow(start: start, end: end)!
    }

    private var selectedOffPeakWindow: WiltedAutomationOffPeakWindow {
        if case let .offPeak(window) = model.automationSettings.processingPolicy { return window }
        return defaultOffPeakWindow
    }

    private var isOffPeakProcessing: Bool {
        if case .offPeak = model.automationSettings.processingPolicy { return true }
        return false
    }

    private var offPeakStartBinding: Binding<Date> {
        localTimeBinding(\.start)
    }

    private var offPeakEndBinding: Binding<Date> {
        localTimeBinding(\.end)
    }

    private func localTimeBinding(_ keyPath: KeyPath<WiltedAutomationOffPeakWindow, WiltedAutomationLocalTime>) -> Binding<Date> {
        Binding(
            get: {
                let time = selectedOffPeakWindow[keyPath: keyPath]
                return Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? .now
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                guard let hour = components.hour, let minute = components.minute,
                      let replacement = WiltedAutomationLocalTime(hour: hour, minute: minute) else { return }
                let window = selectedOffPeakWindow
                let start = keyPath == \.start ? replacement : window.start
                let end = keyPath == \.end ? replacement : window.end
                guard let updatedWindow = WiltedAutomationOffPeakWindow(start: start, end: end) else { return }
                replaceAutomationSettings(processingPolicy: .offPeak(updatedWindow))
            }
        )
    }

    private func replaceAutomationSettings(
        refreshPolicy: WiltedAutomationRefreshPolicy? = nil,
        downloadPolicy: WiltedAutomationDownloadPolicy? = nil,
        processingPolicy: WiltedAutomationProcessingPolicy? = nil,
        transcriptPolicy: WiltedAutomationTranscriptPolicy? = nil,
        removeAds: Bool? = nil,
        autoAddPreparedToMenu: Bool? = nil,
        downloadEverythingOnMenu: Bool? = nil,
        prepareEverythingDownloaded: Bool? = nil
    ) {
        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: refreshPolicy ?? settings.refreshPolicy,
                downloadPolicy: downloadPolicy ?? settings.downloadPolicy,
                processingPolicy: processingPolicy ?? settings.processingPolicy,
                transcriptPolicy: transcriptPolicy ?? settings.transcriptPolicy,
                removeAds: removeAds ?? settings.removeAds,
                autoAddPreparedToMenu: autoAddPreparedToMenu ?? settings.autoAddPreparedToMenu,
                downloadEverythingOnMenu: downloadEverythingOnMenu ?? settings.downloadEverythingOnMenu,
                prepareEverythingDownloaded: prepareEverythingDownloaded ?? settings.prepareEverythingDownloaded
            )
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
