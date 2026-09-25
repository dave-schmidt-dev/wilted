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
    @Binding var presentation: WiltedMacPlayerSection?
    let focusRequest: WiltedMacPlayerSection?
    @Environment(\.colorScheme) var colorScheme
    @State var dropTargetID: String?

    var body: some View {
        WiltedMacDestination(title: "Larder", identifier: "wilted-mac-menu-detail") {
            Text("Playback follows Ready episodes from top to bottom and skips rows that are not ready. Needs preparation has downloaded audio; Not downloaded needs downloading.")
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

            filterBar
            groupList
            articlesSection
        }
        .searchable(text: $model.librarySearchQuery,
                    prompt: "Search titles, shows, notes, and transcripts")
    }

}
