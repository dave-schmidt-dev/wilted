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
    @Environment(\.colorScheme) var colorScheme
    @State var dropTargetID: String?

    var body: some View {
        WiltedMacDestination(
            title: "Larder",
            identifier: "wilted-mac-menu-detail",
            contentWidth: paneMode == .side ? nil : 760,
            inset: paneMode == .side ? WiltedTheme.Spacing.large : WiltedTheme.Spacing.section,
            watermark: true,
            scrollAnchor: model.scrollAnchor(for: .menu)
        ) {
            if paneMode == .bottom { bottomModeHeader }
            larderList
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
                Text("Ready: \(model.menuUnfilteredEpisodes(in: .playable).count) episodes")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-menu-waiting-count")
                // Absent before the first refresh, so a Larder that has never refreshed reads as it did.
                if model.lastPodcastRefreshAt != nil {
                    WiltedMacLastRefreshedLabel(model: model, identifier: "wilted-menu-last-refreshed")
                }
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
                    // submenu on macOS. Direct menu buttons keep every order
                    // in one click target while
                    // retaining the same persisted model binding.
                    ForEach(WiltedMacMenuSort.presentationOptions, id: \.id) { option in
                        Button {
                            model.menuSort = option
                        } label: {
                            if model.menuSort.canonical == option {
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
                if model.menuSort != .custom {
                    Button {
                        let direction = model.menuSortDirection.reversed
                        model.menuSort = model.menuSort.canonical
                        model.menuSortDirection = direction
                    } label: {
                        Image(systemName: model.menuSortDirection == .ascending ? "arrow.up" : "arrow.down")
                            .wiltedFont(.utility)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Sort direction: \(model.menuSortDirection.displayName)")
                    .accessibilityLabel("Larder sort direction: \(model.menuSortDirection.displayName)")
                    .accessibilityIdentifier("wilted-menu-sort-direction")
                }
            }
        }

        filterBar
        groupList.wiltedMarksRowsTop()
        articlesSection
    }
}
