import AppKit
import SwiftUI
import WiltedProducer

/// The navigation column: destinations, and the waiting totals beneath them.
///
/// Narrow windows swap the labelled form for an icon-only rail. The rail keeps
/// every destination one click away -- a tooltip and an accessibility label
/// carry the name the text no longer does -- and keeps only the Ready total,
/// as an icon over the compact time. The column is never hidden.
struct WiltedMacSidebar: View {
    @Bindable var model: WiltedMacModel
    let mode: WiltedMacSidebarMode
    let onSelect: (WiltedMacNavigation) -> Void
    @Environment(\.colorScheme) var colorScheme

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
                playlistsSection
            }
            // The sidebar carries a page-token background rather than the
            // default AppKit material. It matches the rest of the palette, and
            // the material was additionally invisible to offscreen rendering,
            // which is why the navigation column recorded as a blank rectangle
            // in every Mac pixel baseline.
            .accessibilityIdentifier("wilted-mac-sidebar")
            .scrollContentBackground(.hidden)
            .background(WiltedTheme.color(.page, scheme: colorScheme))
            .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
            .task { await model.loadPlaylists() }
            if mode == .full { totals } else { railReadyTotal }
            publicationFooter
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .modifier(WiltedMacPlaylistPrompts(model: model))
    }

    private var publicationFooter: some View {
        let summary = WiltedPublicationAge.macSidebarSummary(
            model.librarySyncActivity.publication?.publishedAt, verified: model.libraryPublicationVerified,
            held: model.libraryAccountStatus?.needsReview == true)
        let detail = [model.libraryPublicationDetail, model.libraryPublicationQualifier].compactMap { $0 }.joined(separator: " ")
        let failed = model.librarySyncActivity.sendFailed || model.librarySyncActivity.checkFailed
        return Group {
            if mode == .full {
                Text(summary)
                    // Prose fits the actual sidebar in the native proportional caption; shrinking
                    // the theme's monospaced caption made “sync” unreadable in shipping captures.
                    .font(.system(size: WiltedTheme.scaled(NSFont.preferredFont(forTextStyle: .caption1).pointSize, scale: model.textScale)))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Image(systemName: failed ? "exclamationmark.triangle" : "iphone")
                    .wiltedFont(.body)
                    .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(WiltedTheme.color(failed ? .degraded : .secondaryText, scheme: colorScheme))
        .padding(.horizontal, WiltedTheme.Spacing.small)
        .padding(.bottom, WiltedTheme.Spacing.small)
        .help("\(summary). \(detail)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary). \(detail)")
        .accessibilityIdentifier("wilted-sidebar-publication-status")
    }

    func row(_ destination: WiltedMacNavigation) -> some View {
        WiltedMacSidebarRow(
            destination: destination, count: model.sidebarCount(for: destination), mode: mode,
            isSelected: model.selectedNavigation == destination, textScale: model.textScale
        ) { onSelect(destination) }
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
                summary: model.larderGroupAudioSummary(.playable),
                identifier: "wilted-sidebar-ready-total"
            )
            total(
                "Needs Prep",
                summary: model.larderGroupAudioSummary(.downloaded),
                identifier: "wilted-sidebar-downloaded-total",
                spokenName: "Needs preparation"
            )
            total(
                "In Larder",
                summary: model.larderAudioSummary,
                identifier: "wilted-sidebar-larder-total"
            )
        }
        .padding(.horizontal, WiltedTheme.Spacing.medium)
        .padding(.bottom, WiltedTheme.Spacing.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-sidebar-totals")
    }

    /// The rail's one total: the Ready time under a play icon, in the compact
    /// form the Larder's group headings use. The name moves to the tooltip
    /// and accessibility label; an unknown duration count does not fit and
    /// stays with the full sidebar.
    private var railReadyTotal: some View {
        let summary = model.larderGroupAudioSummary(.playable)
        return VStack(spacing: WiltedTheme.Spacing.xSmall) {
            Divider()
            Image(systemName: "play.circle")
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .wiltedFont(.body)
                .accessibilityHidden(true)
            Text(summary.label)
                .wiltedFont(.caption)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
        }
        .padding(.horizontal, WiltedTheme.Spacing.xSmall)
        .padding(.bottom, WiltedTheme.Spacing.medium)
        .help("Ready: \(summary.detailLabel)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ready, \(summary.detailLabel)")
        .accessibilityIdentifier("wilted-sidebar-ready-total")
    }

    /// One sidebar waiting time. The figure and its unknown count come from
    /// the same summary the matching Larder heading counts, so the two surfaces
    /// cannot disagree, and an unknown duration is shown as a count rather
    /// than silently summed as zero.
    private func total(
        _ label: String, summary: WiltedMacQueueAudioSummary, identifier: String,
        spokenName: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .accessibilityLabel(spokenName ?? label)
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

/// Shipping row contents resolve appearance within the view graph, including focused captures.
struct WiltedMacSidebarRow: View {
    let destination: WiltedMacNavigation
    /// The row's name when it is not the destination's own (a playlist carries its own).
    var title: String?
    /// An icon override for rows whose destination type is not enough to identify them.
    var symbolName: String? = nil
    /// A playlist's kind, tagged beneath its name in the labelled sidebar.
    var playlistKind: PlaylistKind? = nil
    /// The figure beside the name when the reader turned sidebar counts on.
    /// The rail has no room for it, so there it lives in the tooltip and label.
    var count: Int? = nil
    let mode: WiltedMacSidebarMode
    let isSelected: Bool
    let textScale: WiltedTheme.TextScale
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var accessibilityDescription: String {
        let name = title ?? destination.title
        if let count { return "\(name), \(WiltedMacModel.sidebarCountPhrase(count, for: destination))" }
        guard let playlistKind else { return name }
        return "\(name), \(playlistKind.displayName) playlist"
    }

    var body: some View {
        Button {
            onSelect()
        } label: {
            // An explicit Image + Text rather than a Label: on
            // macOS 26+ the sidebar list style tints a Label's
            // icon with the system accent whatever foreground
            // style the Label carries, which is the blue the
            // owner saw. Both halves name their colour here.
            HStack(spacing: WiltedTheme.Spacing.small) {
                Image(symbol: symbolName ?? destination.symbolName)
                    .foregroundStyle(
                        WiltedMacSidebarStyle.iconColor(isSelected: isSelected, scheme: colorScheme)
                    )
                    .frame(width: WiltedTheme.scaled(20, scale: textScale))
                    .accessibilityHidden(true)
                if mode == .full {
                    if let playlistKind {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title ?? destination.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    WiltedMacSidebarStyle.titleColor(isSelected: isSelected, scheme: colorScheme)
                                )
                            WiltedMacPlaylistKindTag(kind: playlistKind)
                        }
                        .layoutPriority(1)
                    } else {
                        Text(title ?? destination.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(
                                WiltedMacSidebarStyle.titleColor(isSelected: isSelected, scheme: colorScheme)
                            )
                    }
                    if let count {
                        Spacer(minLength: WiltedTheme.Spacing.small)
                        Text("\(count)")
                            .wiltedFont(.utility)
                            .monospacedDigit()
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .accessibilityIdentifier("wilted-navigation-\(destination.rawValue)-count")
                    }
                }
            }
            .wiltedFont(.body)
            .frame(maxWidth: .infinity, alignment: mode == .full ? .leading : .center)
            // On the label, not the Button: a plain button hit-tests only its
            // label's drawn content, so the gap between a playlist's name and
            // its kind tag (the row's centre) ignored clicks.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected
                ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.24)
                : Color.clear
        )
        .help(accessibilityDescription)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier("wilted-navigation-\(destination.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
