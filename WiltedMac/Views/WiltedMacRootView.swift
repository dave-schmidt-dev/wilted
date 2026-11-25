import AppKit
import SwiftUI
import WiltedDomain
#if canImport(WiltedProducer)
import WiltedLibrary
import WiltedProducer
#endif

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
/// stay reachable: the player shares one placement across every destination.
struct WiltedMacRootView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var playerPresentation: WiltedMacPlayerSection?
    @State private var playerFocusRequest: WiltedMacPlayerSection?
    @State private var windowWidth: CGFloat = 0
    @State private var paneState = WiltedMacPaneState()
    @State private var headlineToastState = WiltedMacHeadlineToastState()
    @State private var isHoveringHeadlineToast = false
    @State private var headlineToastTimer = WiltedMacHeadlineToastTimer()
    /// Outlives each Feeds visit, so a revisit draws cached capacity while Feeds refreshes it.
    @State private var feedPolicyBoard: WiltedMacFeedPolicyBoard

    /// What the window's width gives the sidebar and the Now Playing pane.
    private var shell: WiltedMacShellLayout {
        WiltedMacShellLayout.resolve(
            for: model.selectedNavigation, windowWidth: windowWidth,
            scale: model.textScale, sidebarVisible: model.isSidebarVisible)
    }
    /// All destinations share the same placement at the same window width.
    private var showsBottomBar: Bool {
        playerPresentation == nil && shell.pane == .bottom
    }

    init(model: WiltedMacModel, initialPlayerPresentation: WiltedMacPlayerSection? = nil) {
        _model = Bindable(model)
        _playerPresentation = State(initialValue: initialPlayerPresentation)
        _feedPolicyBoard = State(initialValue: WiltedMacFeedPolicyBoard(model: model))
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
        // The window's width, not the detail's: the rail hands the detail
        // width back, and a threshold read from it would chase its own result.
        GeometryReader { proxy in
            splitView
                .onChange(of: proxy.size.width, initial: true) { _, width in windowWidth = width }
        }
        .frame(minWidth: WiltedMacShellLayout.windowMinimumWidth(scale: model.textScale))
        .task(id: model.subscriptions.map(\.id)) {
            // Feeds used to start this load on its first visit. The window's
            // board now loads with the ready window, in the background, so the
            // first visit already has complete settings. Hosted tests render
            // this root and must not open the owner's store.
            guard !WiltedMacModel.hostsTests else { return }
            await feedPolicyBoard.reload()
        }
        .overlay(alignment: .top) { headlineToast }
        .onAppear { considerHeadlineToast(headlineToastCandidate) }
        .onChange(of: headlineToastEventID) { _, _ in
            considerHeadlineToast(headlineToastCandidate)
        }
        .onChange(of: headlineToastState.presentationID) { _, presentationID in
            guard presentationID != nil else {
                headlineToastTimer.cancel()
                return
            }
            startHeadlineToastTimer(after: Double(model.headlineToastDurationSeconds))
        }
        .onChange(of: model.headlineToastDurationSeconds) { _, duration in
            guard headlineToastState.story != nil else { return }
            startHeadlineToastTimer(after: Double(duration))
        }
        .onChange(of: model.libraryAccountStatus) { _, _ in
            headlineToastTimer.cancel()
            withAnimation(.easeOut(duration: 0.2)) { headlineToastState.reset() }
        }
        .onDisappear { headlineToastTimer.cancel() }
    }

    private var sidebarColumnWidth: CGFloat {
        shell.sidebar == .rail
            ? WiltedMacShellLayout.railWidth
            : WiltedTheme.scaled(WiltedMacShellLayout.sidebarIdealWidth, scale: model.textScale)
    }

#if canImport(WiltedProducer)
    /// A headline starts its toast only when playback reaches its break.
    private var headlineToastCandidate: LibraryHeadlineStory? {
        guard let bulletin = model.speakingBulletin, bulletin.kind == .headline else { return nil }
        return WiltedMacPlayerContent.selectHeadlineCard(
            speaking: bulletin,
            lastSpokenStoryID: nil,
            pendingStoryID: nil,
            projection: model.headlineCatalogState.projection)
    }

    private var headlineToastEventID: String? {
        if let bulletin = model.speakingBulletin, bulletin.kind == .headline,
           let storyID = bulletin.headlineStoryID {
            return "speaking:\(storyID)"
        }
        return nil
    }

    static func narrationStatus(
        for state: WiltedMacHeadlineNarrationState
    ) -> WiltedMacPlayerHeadlineCard.NarrationStatus? {
        switch state {
        case .chooseVoice:
            .chooseVoice
        case .preparing:
            .preparing
        case .unavailable:
            .unavailable
        case .notScheduled, .ready:
            nil
        }
    }
#endif

    @ViewBuilder
    private var headlineToast: some View {
#if canImport(WiltedProducer)
        if let story = headlineToastState.currentStory(in: model.headlineCatalogState.projection) {
            HStack(alignment: .top, spacing: WiltedTheme.Spacing.small) {
                WiltedMacPlayerHeadlineCard(
                    model: model, story: story,
                    isSpeakingHeadline: model.speakingBulletin?.kind == .headline
                        && model.speakingBulletin?.headlineStoryID == story.id,
                    stopReading: model.skipSpokenBulletin,
                    narrationStatus: Self.narrationStatus(
                        for: model.bulletinHub.headlineNarrationState(for: story.id)))
                    .id(story.id)

                Button {
                    withAnimation(.easeOut(duration: 0.2)) { headlineToastState.dismiss() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss headline")
                .accessibilityIdentifier("wilted-headline-toast-dismiss")
            }
            .padding(WiltedTheme.Spacing.small)
            .frame(maxWidth: 760)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.horizontal, WiltedTheme.Spacing.large)
            .padding(.top, WiltedTheme.Spacing.medium)
            .onHover(perform: setHeadlineToastHover)
            .accessibilityIdentifier("wilted-headline-toast")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
#endif
    }

    private var detail: some View {
        detailContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func considerHeadlineToast(_ story: LibraryHeadlineStory?) {
        guard let story, let eventID = headlineToastEventID else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            _ = headlineToastState.present(story, eventID: eventID)
        }
    }

    private func startHeadlineToastTimer(after seconds: Double) {
        headlineToastTimer.start(after: seconds) {
            guard headlineToastState.story != nil else { return }
            withAnimation(.easeOut(duration: 0.35)) { headlineToastState.dismiss() }
        }
        if isHoveringHeadlineToast { headlineToastTimer.pause() }
    }

    private func setHeadlineToastHover(_ isHovering: Bool) {
        guard isHoveringHeadlineToast != isHovering else { return }
        isHoveringHeadlineToast = isHovering
        guard headlineToastState.story != nil else { return }
        if isHovering { headlineToastTimer.pause() } else { headlineToastTimer.resume() }
    }

    private var detailContent: some View {
        ZStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Group {
                            switch model.selectedNavigation {
                            case .feeds:
                                WiltedMacFeedsView(model: model, policyBoard: feedPolicyBoard)
                            case .notebook:
                                WiltedMacNotebookView(model: model)
                            case .larder:
                                WiltedMacLarderView(
                                    model: model, paneMode: shell.pane, sidebarMode: shell.sidebar,
                                    policyBoard: feedPolicyBoard
                                )
                            case .settings:
                                WiltedMacSettingsView(model: model, policyBoard: feedPolicyBoard)
                            case .playlist(let id):
                                WiltedMacPlaylistView(model: model, playlistID: id)
                            }
                        }
                        if shell.pane == .side {
                            Divider()
                            WiltedMacNowPlayingPane(model: model, state: $paneState)
                                .frame(width: WiltedMacLarderLayout.paneColumnWidth(detailWidth: geometry.size.width))
                        }
                    }
                }
                // Over the content and clear of the bottom bar. The full-window
                // player covers this region, so it carries the toast itself.
                .modifier(WiltedMacUndoToastHost(center: model.undoToast, isPresenting: playerPresentation == nil))
                if showsBottomBar {
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
            // Every destination shares the side pane or the bottom bar,
            // plus the full-window presentation here.
            .allowsHitTesting(playerPresentation == nil)
            .accessibilityHidden(playerPresentation != nil)
            .disabled(playerPresentation != nil)

            if playerPresentation != nil {
                WiltedMacFullWindowPlayer(
                    model: model,
                    presentation: $playerPresentation,
                    onSelect: { playerPresentation = $0 },
                    onCollapse: { section in
                        playerPresentation = nil
                        playerFocusRequest = section
                        paneState.collapsed(to: section)
                    }
                )
                .modifier(WiltedMacUndoToastHost(center: model.undoToast))
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
        .onChange(of: model.currentPodcastEpisodeID) { paneState.episodeChanged() }
    }

    /// The sidebar is a column of this view rather than a NavigationSplitView
    /// column: the split view keeps the width it first laid out and ignores a
    /// new fixed width at run time, so it cannot become a rail on resize. The
    /// sidebar already draws its own page background, so nothing native is lost.
    private var splitView: some View {
        HStack(spacing: 0) {
            WiltedMacSidebar(model: model, mode: shell.sidebar) {
                model.selectedNavigation = $0
            }
            .frame(width: sidebarColumnWidth)
            Divider()
            detail
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        .toolbar { wordmark; sidebarToggle; addButton }
        .sheet(isPresented: $model.isPresentingAddSheet) {
            WiltedMacAddSheet(model: model)
        }
        // File > Prepare Again With Current Engine asks once for the whole set,
        // naming how many runs it starts. Each run keeps the listener's place.
        // It hangs on the window root so the command works from any section.
        .confirmationDialog(
            WiltedMacModel.prepareAgainConfirmationTitle(count: model.episodesToPrepareAgain.count),
            isPresented: $model.isConfirmingPrepareAgainAll,
            titleVisibility: .visible
        ) {
            Button("Prepare Again") { model.prepareAgainAll() }
                .accessibilityIdentifier("wilted-larder-prepare-again-all-confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("wilted-larder-prepare-again-all-cancel")
        } message: {
            Text(WiltedMacModel.prepareAgainConfirmationMessage)
        }
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
        // Three names for the same thing sat in one toolbar: the mark, the
        // window title beside it, and the destination heading below. macOS 26
        // draws the title as its own toolbar item, which `titleVisibility`
        // no longer suppresses, so remove the item where the API exists and
        // keep the AppKit fallback for macOS 14.
        .wiltedRemovingToolbarTitle()
        .wiltedTransparentToolbar()
        .background(WiltedWindowTitleHider())
        .background {
            if let width = WiltedMacFixtureWindowWidth.width(arguments: model.launchArguments) {
                WiltedMacFixtureWindowSizer(width: width)
            }
        }
        .accessibilityIdentifier("wilted-mac-root")
    }

    private var startupLoading: some View {
        VStack(spacing: WiltedTheme.Spacing.medium) {
            // The current bootstrap phase, not one fixed sentence: a store
            // migration that takes a while should say which wait this is.
            WiltedLoadingMotif()
            Text(model.startupStepLabel)
                .wiltedFont(.body)
                .accessibilityLabel(model.startupStepLabel)
            Text("Your saved library stays in place while Wilted checks its format.")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WiltedLoadingMotifGeometry.surface(colorScheme))
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
                DisclosureGroup("Show details") {
                    Text(detail)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("wilted-mac-startup-error-detail")
                }
                .accessibilityIdentifier("wilted-mac-startup-error-details")
            }
            if let recoveryURL = failure.recoveryCopyURL {
                Text("A recovery copy of your previous library is at:")
                    .wiltedFont(.body)
                Text(recoveryURL.path)
                    .wiltedFont(.utility)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("wilted-mac-retained-v5-location")
                Button("Show Recovery Copy in Finder") {
                    model.presentRecoveryCopy()
                }
                .accessibilityIdentifier("wilted-mac-show-retained-v5")
            }
            if failure.canRetry {
                Button("Retry Opening Your Library") {
                    model.retryStoreBootstrap()
                }
                .accessibilityIdentifier("wilted-mac-startup-retry")
            } else {
                Text("Wilted stopped retrying. Quit, then open Wilted again to try once more.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                Button("Quit Wilted") { NSApplication.shared.terminate(nil) }
                    .accessibilityIdentifier("wilted-mac-startup-quit")
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WiltedTheme.Spacing.section)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WiltedMacStartupAccessibility.recovery)
    }

    /// Collapse or expand sidebar labels. ⌃⌘S does the same from the View menu.
    @ToolbarContentBuilder
    private var sidebarToggle: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            sidebarToggleContent
        }
    }

    /// Shipping toolbar contents also render without AppKit chrome in headless tests.
    var sidebarToggleContent: some View {
        Button {
            model.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.leading")
        }
        .help(model.sidebarToggleTitle)
        .accessibilityLabel(model.sidebarToggleTitle)
        .accessibilityIdentifier("wilted-sidebar-toggle")
    }

    /// The one way in for anything new: a podcast search, a feed, an article.
    @ToolbarContentBuilder
    private var addButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            addButtonContent
        }
    }

    /// Also renders without AppKit chrome in headless tests. The ⌘N shortcut lives on the File > New command in WiltedMacApp.
    var addButtonContent: some View {
        Button {
            model.presentAddSheet()
        } label: {
            Label("Add", systemImage: "plus")
        }
        .help("Add a podcast or article (\u{2318}N)")
        .accessibilityIdentifier("wilted-add-button")
    }

    var wordmarkContent: some View { WiltedWordmark(height: 16) }

    /// The wordmark states the brand at the top of the window. macOS 26 gives
    /// every toolbar item a glass capsule, which reads as a stray button
    /// behind letterforms that already have their own silhouette, so the
    /// shared background is opted out of where the API exists.
    @ToolbarContentBuilder
    private var wordmark: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                wordmarkContent
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                wordmarkContent
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

/// A toolbar over the window's own page, with no band of its own.
///
/// Every destination fills the window under the toolbar with its page colour, so
/// the toolbar has nothing to float over. On macOS 26 the system still draws a
/// backing for it, and a scroll-edge effect over the scroll views beneath, which
/// showed as a grey band across the toolbar on hover. Both are hidden where the
/// API exists: the toolbar background from macOS 15, the top scroll-edge effect
/// from macOS 26. Hiding the effect on this ancestor reaches every scroll view
/// under it, the sidebar's list included.
private extension View {
    @ViewBuilder
    func wiltedTransparentToolbar() -> some View {
        if #available(macOS 26.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .scrollEdgeEffectHidden(true, for: .top)
        } else if #available(macOS 15.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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

/// Shared explanatory content, rendered by the same native popover and focused captures.
struct WiltedMacHelpContent: View {
    let title: String
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text(title).wiltedFont(.title)
            Text(text).wiltedFont(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
        .padding(WiltedTheme.Spacing.medium)
        .frame(maxWidth: 360, alignment: .leading)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .combine)
    }
}

/// A native info button keeps explanatory copy beside its section, outside the main flow.
struct WiltedMacHelpButton: View {
    let content: WiltedMacHelpContent
    let identifier: String
    @State private var isPresented = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: "info.circle").wiltedFont(.body)
        }
        .buttonStyle(.plain)
        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        .help("About \(content.title)")
        .accessibilityLabel("About \(content.title)")
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { content }
    }
}
