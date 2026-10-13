import SwiftUI

/// Player titles retain their label identity and open details for episodes only.
struct WiltedMacPlayerEpisodeTitle: View {
    @Bindable var model: WiltedMacModel
    let title: String
    let font: WiltedTheme.TypographyRole
    let titleLineLimit: Int
    let labelIdentifier: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let episode = model.currentEpisode {
            WiltedMacPlayingEpisodeTitle(
                model: model, episode: episode, font: font,
                titleLineLimit: titleLineLimit, labelIdentifier: labelIdentifier)
                .id(episode.id)
        } else {
            Text(title)
                .wiltedFont(font)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .multilineTextAlignment(.leading)
                .lineLimit(titleLineLimit)
                .accessibilityIdentifier(labelIdentifier)
        }
    }
}

private struct WiltedMacPlayingEpisodeTitle: View {
    let model: WiltedMacModel
    let episode: WiltedMacEpisode
    let font: WiltedTheme.TypographyRole
    let titleLineLimit: Int
    let labelIdentifier: String
    @State private var isPresented = false
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button { isPresented = true } label: {
            Text(episode.title)
                .wiltedFont(font)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .multilineTextAlignment(.leading)
                .lineLimit(titleLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .underline(isHovering)
                .accessibilityIdentifier(labelIdentifier)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Show notes for \(episode.title)")
        .accessibilityLabel("Show notes for \(episode.title)")
        .accessibilityIdentifier("wilted-player-show-notes-\(episode.id)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            WiltedMacEpisodeNotes(
                episode: episode, prefix: "wilted-player",
                source: model.episodeInfoSource(id: episode.id, showTitle: episode.feedTitle)
            ) { EmptyView() }
        }
    }
}
