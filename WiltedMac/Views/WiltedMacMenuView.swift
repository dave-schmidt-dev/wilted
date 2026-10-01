import AppKit
import SwiftUI
import WiltedDomain

// MARK: - Menu

/// The one place episodes wait: the retired Larder and Menu were the same
/// idea twice. Rows read in a fixed order -- Ready, Downloaded, Available --
/// because an episode can be downloaded, then prepared, then played, and the
/// list says which step is next. Filters and bulk actions read through the
/// same group accessor the rows do, so no count can label a list it does not
/// match.
struct WiltedMacMenuView: View {
    static let readyActionSlotWidth: CGFloat = 28
    static let trailingActionSlotsWidth: CGFloat = 58

    @Bindable var model: WiltedMacModel
    /// Where the Now Playing pane sits, decided from the window's width by
    /// the root: beside the list, or in the bar the root draws beneath it.
    let paneMode: WiltedMacPaneMode
    /// The section the full-window player last collapsed to, if any.
    let collapsedSection: WiltedMacPlayerSection?
    @State private var paneState = WiltedMacPaneState()
    @Environment(\.colorScheme) var colorScheme
    @State var dropTargetID: String?

    var body: some View {
        // One list view in both compositions, at the same place in the
        // hierarchy: only its header and the pane beside it come and go.
        // Two separate subtrees would be torn down and rebuilt each time
        // the window crossed the threshold, resetting the list's scroll
        // position. The pane's own state lives on this view for the same
        // reason -- the pane is unmounted whenever it is at the bottom.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                WiltedMacDestination(
                    title: "Larder",
                    identifier: "wilted-mac-menu-detail",
                    contentWidth: paneMode == .side ? nil : 760,
                    inset: paneMode == .side ? WiltedTheme.Spacing.large : WiltedTheme.Spacing.section,
                    watermark: true
                ) {
                    if paneMode == .bottom { bottomModeHeader }
                    larderList
                }
                if paneMode == .side {
                    Divider()
                    WiltedMacNowPlayingPane(model: model, state: $paneState)
                        .frame(width: WiltedMacLarderLayout.paneColumnWidth(detailWidth: geometry.size.width))
                }
            }
        }
        // A new episode starts at its own line, not wherever the last was.
        // Observed here because this view owns the state and outlives the
        // pane, which is unmounted whenever it is at the bottom.
        .onChange(of: model.currentPodcastEpisodeID) { paneState.episodeChanged() }
        .onChange(of: collapsedSection) { _, section in
            if let section { paneState.collapsed(to: section) }
        }
        .searchable(text: $model.librarySearchQuery, prompt: "Search episodes")
    }

    /// How playback follows the list, when the pane is in the bar below.
    @ViewBuilder private var bottomModeHeader: some View {
        Text("Playback follows Ready episodes from top to bottom and skips rows that are not ready. Needs preparation has downloaded audio; Not downloaded needs downloading.")
            .wiltedFont(.body)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Totals, grouping and sort, filters, the grouped rows and the articles:
    /// the Larder itself, shared by both compositions.
    @ViewBuilder private var larderList: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text("Audio in Larder: \(model.menuAudioSummary.detailLabel)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-menu-audio-total")
                Text("Waiting for you: \(model.menuWaitingEpisodes.count) episodes")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-menu-waiting-count")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WiltedMacFlowLayout {
                Menu {
                    ForEach(Array(WiltedMacMenuGrouping.allCases), id: \.id) { option in
                        Button {
                            model.menuGrouping = option
                        } label: {
                            if model.menuGrouping == option {
                                Label(option.rawValue, systemImage: "checkmark")
                            } else {
                                Text(option.rawValue)
                            }
                        }
                    }
                } label: {
                    Label("Group by: \(model.menuGrouping.rawValue)", systemImage: "rectangle.3.group")
                        .wiltedFont(.utility)
                }
                .menuStyle(.button)
                .controlSize(.regular)
                .accessibilityLabel("Group Larder by: \(model.menuGrouping.rawValue)")
                .accessibilityIdentifier("wilted-menu-grouping")
                Menu {
                    // A Picker nested inside this Menu creates a second
                    // submenu on macOS. Choosing Custom order dismisses that
                    // submenu before the listener can reach Oldest. Direct
                    // menu buttons keep every order in one click target while
                    // retaining the same persisted model binding.
                    ForEach(Array(WiltedMacMenuSort.allCases), id: \.id) { option in
                        Button {
                            model.menuSort = option
                        } label: {
                            if model.menuSort == option {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                } label: {
                    Label("Sort by: \(model.menuSort.displayName)", systemImage: "arrow.up.arrow.down")
                        .wiltedFont(.utility)
                }
                .menuStyle(.button)
                .controlSize(.regular)
                .accessibilityLabel("Sort Larder: \(model.menuSort.displayName)")
                .accessibilityIdentifier("wilted-menu-sort")
            }
        }

        filterBar
        groupList.wiltedMarksRowsTop()
        articlesSection
    }
}
