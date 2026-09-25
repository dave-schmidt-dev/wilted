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
            // The totals sit outside the List, so they stay pinned to the
            // bottom of the column instead of scrolling away under the
            // destinations as the navigation list grows.
            VStack(spacing: 0) {
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
                }
                // The sidebar carries a page-token background rather than the
                // default AppKit material. It matches the rest of the palette, and
                // the material was additionally invisible to offscreen rendering,
                // which is why the navigation column recorded as a blank rectangle
                // in every Mac pixel baseline.
                .scrollContentBackground(.hidden)
                .background(WiltedTheme.color(.page, scheme: colorScheme))
                sidebarTotals
            }
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

    /// The three waiting times, pinned to the bottom of the sidebar column.
    /// Outside the List on purpose: they are a standing readout of what is
    /// waiting, not another row to scroll past. No heading: each row names
    /// itself, so a label over them only repeats what they already say.
    private var sidebarTotals: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Divider()
            sidebarTotal(
                "Ready",
                summary: model.menuGroupAudioSummary(.playable),
                identifier: "wilted-sidebar-ready-total"
            )
            sidebarTotal(
                "Needs preparation",
                summary: model.menuGroupAudioSummary(.downloaded),
                identifier: "wilted-sidebar-downloaded-total"
            )
            sidebarTotal(
                "In Larder",
                summary: model.menuAudioSummary,
                identifier: "wilted-sidebar-menu-total"
            )
        }
        .padding(.horizontal, WiltedTheme.Spacing.medium)
        .padding(.bottom, WiltedTheme.Spacing.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-sidebar-totals")
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
struct WiltedMacDestination<Content: View>: View {
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
