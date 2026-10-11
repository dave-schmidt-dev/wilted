import AppKit
import SwiftUI
import WiltedDomain

// MARK: - Larder

/// The one place episodes wait: the retired Larder and Larder were the same
/// idea twice. Rows read in a fixed order -- Ready, Downloaded, Available --
/// because an episode can be downloaded, then prepared, then played, and the
/// list says which step is next. Filters and bulk actions read through the
/// same group accessor the rows do, so no count can label a list it does not
/// match.
struct WiltedMacLarderView: View {
    static let readyActionSlotWidth: CGFloat = 64
    static let trailingActionSlotsWidth: CGFloat = 58

    @Bindable var model: WiltedMacModel
    /// Where the Now Playing pane sits, decided from the window's width by
    /// the root: beside the list, or in the bar the root draws beneath it.
    let paneMode: WiltedMacPaneMode
    let sidebarMode: WiltedMacSidebarMode

    init(model: WiltedMacModel, paneMode: WiltedMacPaneMode, sidebarMode: WiltedMacSidebarMode = .rail) {
        self.model = model
        self.paneMode = paneMode
        self.sidebarMode = sidebarMode
    }
    @Environment(\.colorScheme) var colorScheme
    @State var dropTargetID: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        WiltedMacDestination(
            title: "Larder",
            identifier: "wilted-mac-larder-detail",
            contentWidth: paneMode == .side ? nil : 760,
            inset: paneMode == .side ? WiltedTheme.Spacing.large : WiltedTheme.Spacing.section,
            watermark: true,
            scrollAnchor: model.scrollAnchor(for: .larder)
        ) {
            if paneMode == .bottom { bottomModeHeader }
            larderList
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                TextField("", text: $model.librarySearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
                    .focusedSceneValue(\.wiltedLarderSearchFocus, { isSearchFocused = true })
                    .frame(width: 160)
                    .accessibilityLabel("Search episodes")
                    .accessibilityIdentifier("wilted-larder-search")
            }
        }
    }

    var playbackHelp: WiltedMacHelpContent {
        WiltedMacHelpContent(title: "Playback order", text:
            "Playback follows Ready episodes from top to bottom and skips rows that are not ready. Needs preparation has downloaded audio; Not downloaded needs downloading.")
    }

    @ViewBuilder private var bottomModeHeader: some View {
        WiltedMacHelpButton(content: playbackHelp, identifier: "wilted-larder-playback-help")
    }

    /// The kind filter: everything, or only podcasts, articles or audiobooks. It narrows the one
    /// grouped list and never reorders what plays.
    private var kindMenu: some View {
        Menu {
            ForEach(WiltedMacLarderKind.allCases) { option in
                Button {
                    model.larderKind = option
                } label: {
                    if model.larderKind == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            Label("Show: \(model.larderKind.rawValue)", systemImage: "line.3.horizontal.decrease")
                .wiltedFont(.utility)
        }
        .menuStyle(.button)
        .controlSize(.regular)
        .accessibilityLabel("Show in Larder: \(model.larderKind.rawValue)")
        .accessibilityIdentifier("wilted-larder-kind")
    }

    /// Totals, grouping and sort, filters and the grouped rows of episodes, audiobooks and
    /// articles: the Larder itself, shared by both compositions.
    @ViewBuilder private var larderList: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                if sidebarMode != .full {
                    Text("Audio in Larder: \(model.larderAudioSummary.detailLabel)")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-larder-audio-total")
                }
                // Absent before the first refresh, so a Larder that has never refreshed reads as it did.
                if model.lastPodcastRefreshAt != nil {
                    WiltedMacLastRefreshedLabel(model: model, identifier: "wilted-larder-last-refreshed")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WiltedMacFlowLayout {
                Menu {
                    ForEach(Array(WiltedMacLarderGrouping.allCases), id: \.id) { option in
                        Button {
                            model.larderGrouping = option
                        } label: {
                            if model.larderGrouping == option {
                                Label(option.rawValue, systemImage: "checkmark")
                            } else {
                                Text(option.rawValue)
                            }
                        }
                    }
                } label: {
                    Label("Group by: \(model.larderGrouping.rawValue)", systemImage: "rectangle.3.group")
                        .wiltedFont(.utility)
                }
                .menuStyle(.button)
                .controlSize(.regular)
                .accessibilityLabel("Group Larder by: \(model.larderGrouping.rawValue)")
                .accessibilityIdentifier("wilted-larder-grouping")
                Menu {
                    // A Picker nested inside this Larder creates a second
                    // submenu on macOS. Direct menu buttons keep every order
                    // in one click target while
                    // retaining the same persisted model binding.
                    ForEach(WiltedMacLarderSort.presentationOptions, id: \.id) { option in
                        Button {
                            model.larderSort = option
                        } label: {
                            if model.larderSort.canonical == option {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                } label: {
                    Label("Sort by: \(model.larderSort.displayName)", systemImage: "arrow.up.arrow.down")
                        .wiltedFont(.utility)
                }
                .menuStyle(.button)
                .controlSize(.regular)
                .accessibilityLabel("Sort Larder: \(model.larderSort.displayName)")
                .accessibilityIdentifier("wilted-larder-sort")
                kindMenu
                if model.larderSort != .custom {
                    Button {
                        let direction = model.larderSortDirection.reversed
                        model.larderSort = model.larderSort.canonical
                        model.larderSortDirection = direction
                    } label: {
                        Image(systemName: model.larderSortDirection == .ascending ? "arrow.up" : "arrow.down")
                            .wiltedFont(.utility)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Sort direction: \(model.larderSortDirection.displayName)")
                    .accessibilityLabel("Larder sort direction: \(model.larderSortDirection.displayName)")
                    .accessibilityIdentifier("wilted-larder-sort-direction")
                }
                addArticleButton
            }
        }

        filterBar(colorScheme: colorScheme)
        groupList.wiltedMarksRowsTop()
    }
}

/// The active Larder window supplies its own search focus action to the native Find command.
private struct WiltedMacLarderSearchFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var wiltedLarderSearchFocus: (() -> Void)? {
        get { self[WiltedMacLarderSearchFocusKey.self] }
        set { self[WiltedMacLarderSearchFocusKey.self] = newValue }
    }
}
