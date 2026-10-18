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
    /// The row whose possible duplicate review sheet is open.
    @State var reviewTarget: WiltedMacEpisodeIdentityReviewRequest?
    @State private var searchFocusAction: (() -> Void)?

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
                WiltedMacLarderSearchField(query: $model.librarySearchQuery) { searchFocusAction = $0 }
                    .frame(width: 160)
            }
        }
        .focusedSceneValue(\.wiltedLarderSearchFocus, searchFocusAction)
        .sheet(item: $reviewTarget) { request in
            WiltedMacEpisodeIdentityReview(model: model, anchorID: request.anchorID)
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
            // One operation message for the whole list: reorder, download,
            // preparation, completion and Undo all report where the owner is
            // looking, never once per row.
            WiltedMacPodcastOperationMessage(model: model)
            WiltedMacLarderArticlePreparationRow(model: model)
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
                WiltedMacEpisodeListSortControls(
                    label: "Larder", identifierPrefix: "wilted-larder",
                    sort: $model.larderSort, direction: $model.larderSortDirection
                )
                kindMenu
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
