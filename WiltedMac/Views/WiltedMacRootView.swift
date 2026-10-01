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
    @State private var windowWidth: CGFloat = 0

    /// What the window's width gives the sidebar and the Now Playing pane.
    private var shell: WiltedMacShellLayout {
        WiltedMacShellLayout.resolve(windowWidth: windowWidth, scale: model.textScale)
    }
    /// The bar beneath the destination: for the work destinations always, and
    /// for the Larder once its pane has left the side.
    private var showsBottomBar: Bool {
        playerPresentation == nil && (model.selectedNavigation != .menu || shell.pane == .bottom)
    }

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
        // The window's width, not the detail's: the rail hands the detail
        // width back, and a threshold read from it would chase its own result.
        GeometryReader { proxy in
            splitView
                .onChange(of: proxy.size.width, initial: true) { _, width in windowWidth = width }
        }
        .frame(minWidth: WiltedMacShellLayout.windowMinimumWidth(scale: model.textScale))
    }

    private var sidebarColumnWidth: CGFloat {
        shell.sidebar == .rail
            ? WiltedMacShellLayout.railWidth
            : WiltedTheme.scaled(WiltedMacShellLayout.sidebarIdealWidth, scale: model.textScale)
    }

    private var detail: some View {
        ZStack {
            VStack(spacing: 0) {
                Group {
                    switch model.selectedNavigation {
                    case .feeds:
                        WiltedMacFeedsView(model: model)
                    case .menu:
                        WiltedMacMenuView(model: model, paneMode: shell.pane, collapsedSection: playerFocusRequest)
                    case .settings:
                        WiltedMacSettingsView(model: model)
                    }
                }
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
            // Every destination, the Larder included, uses the bar below
            // and the full-window presentation here: the Larder's pane
            // is either beside the list or in that bar.
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

    /// The sidebar is a column of this view rather than a NavigationSplitView
    /// column: the split view keeps the width it first laid out and ignores a
    /// new fixed width at run time, so it cannot become a rail on resize. The
    /// sidebar already draws its own page background, so nothing native is lost.
    private var splitView: some View {
        HStack(spacing: 0) {
            WiltedMacSidebar(model: model, mode: shell.sidebar) {
                playerFocusRequest = nil
                model.selectedNavigation = $0
            }
            .frame(width: sidebarColumnWidth)
            Divider()
            detail
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        .toolbar { wordmark }
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
            if let width = WiltedMacFixtureWindowWidth.width(arguments: ProcessInfo.processInfo.arguments) {
                WiltedMacFixtureWindowSizer(width: width)
            }
        }
        .accessibilityIdentifier("wilted-mac-root")
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

/// Every destination opens with its own name, at one weight, in one place.
/// Three different title treatments across the two apps is what let a
/// composer heading pass for a destination heading.
struct WiltedMacDestination<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let identifier: String
    /// The reading column's cap. Nil fills the region it is given, for a
    /// destination that is itself one pane of a wider composition.
    var contentWidth: CGFloat? = 760
    var inset: CGFloat = WiltedTheme.Spacing.section
    /// The lettuce over the page, as on iOS's Larder and Settings. It sits over
    /// the scroll view's frame, so it never moves with the text or under the pane.
    var watermark = false
    @ViewBuilder let content: Content
    /// Where the destination's rows begin, as the content reports it: the
    /// lettuce sits below everything above them.
    @State private var rowsTop: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xLarge) {
                Text(title)
                    .wiltedFont(.display)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                content
            }
            .frame(maxWidth: contentWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(inset)
            .coordinateSpace(name: WiltedMacRowsTopKey.space)
            .onPreferenceChange(WiltedMacRowsTopKey.self) { rowsTop = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        // Over the rows, as on iOS, whose list rows are opaque cards: behind
        // them the lettuce would never show. Faint and untouchable, so text
        // contrast and clicks are unaffected.
        .overlay { if watermark { LibraryWatermark(fitting: true, topInset: rowsTop) } }
        .accessibilityIdentifier(identifier)
    }
}

/// Where a destination's rows begin, measured from the top of its scrolled
/// content, which is where the viewport starts before any scrolling.
struct WiltedMacRowsTopKey: PreferenceKey {
    static let space = "wilted-destination-content"
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Marks the start of a destination's rows for its watermark.
    func wiltedMarksRowsTop() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WiltedMacRowsTopKey.self,
                    value: proxy.frame(in: .named(WiltedMacRowsTopKey.space)).minY)
            }
        }
    }
}

/// The offer to follow a feed an added page advertises.
struct WiltedMacAdvertisedFeedOffer: View {
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
