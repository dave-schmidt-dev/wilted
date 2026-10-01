import SwiftUI

/// The navigation column: destinations, and the waiting totals beneath them.
///
/// Narrow windows swap the labelled form for an icon-only rail. The rail keeps
/// every destination one click away -- a tooltip and an accessibility label
/// carry the name the text no longer does -- and drops the totals, which have
/// no room. The column is never hidden.
struct WiltedMacSidebar: View {
    @Bindable var model: WiltedMacModel
    let mode: WiltedMacSidebarMode
    let onSelect: (WiltedMacNavigation) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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
                    row(destination)
                }
            }
            // The sidebar carries a page-token background rather than the
            // default AppKit material. It matches the rest of the palette, and
            // the material was additionally invisible to offscreen rendering,
            // which is why the navigation column recorded as a blank rectangle
            // in every Mac pixel baseline.
            .scrollContentBackground(.hidden)
            .background(WiltedTheme.color(.page, scheme: colorScheme))
            .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
            if mode == .full { totals }
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityIdentifier("wilted-mac-sidebar")
    }

    private func row(_ destination: WiltedMacNavigation) -> some View {
        let isSelected = model.selectedNavigation == destination
        return Button {
            onSelect(destination)
        } label: {
            // An explicit Image + Text rather than a Label: on
            // macOS 26+ the sidebar list style tints a Label's
            // icon with the system accent whatever foreground
            // style the Label carries, which is the blue the
            // owner saw. Both halves name their colour here.
            HStack(spacing: WiltedTheme.Spacing.small) {
                Image(symbol: destination.symbolName)
                    .foregroundStyle(
                        WiltedMacSidebarStyle.iconColor(isSelected: isSelected, scheme: colorScheme)
                    )
                    .frame(width: WiltedTheme.scaled(20, scale: model.textScale))
                    .accessibilityHidden(true)
                if mode == .full {
                    Text(destination.title)
                        .foregroundStyle(
                            WiltedMacSidebarStyle.titleColor(isSelected: isSelected, scheme: colorScheme)
                        )
                }
            }
            .wiltedFont(.body)
            .frame(maxWidth: .infinity, alignment: mode == .full ? .leading : .center)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .listRowBackground(
            isSelected
                ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.24)
                : Color.clear
        )
        .help(destination.title)
        .accessibilityLabel(destination.title)
        .accessibilityIdentifier("wilted-navigation-\(destination.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The three waiting times, pinned to the bottom of the sidebar column.
    /// Outside the List on purpose: they are a standing readout of what is
    /// waiting, not another row to scroll past. No heading: each row names
    /// itself, so a label over them only repeats what they already say.
    private var totals: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Divider()
            total(
                "Ready",
                summary: model.menuGroupAudioSummary(.playable),
                identifier: "wilted-sidebar-ready-total"
            )
            total(
                "Needs preparation",
                summary: model.menuGroupAudioSummary(.downloaded),
                identifier: "wilted-sidebar-downloaded-total"
            )
            total(
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
    private func total(
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

}
