import SwiftUI

/// Both library surfaces open the exact row's notes without changing the queue.
struct WiltedMacEpisodeNotesTitle<Content: View>: View {
    let episode: WiltedMacEpisode
    let prefix: String
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button { isPresented = true } label: {
            Text(episode.title)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .lineLimit(1)
                .underline(isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Show notes for \(episode.title)")
        .accessibilityLabel("Show notes for \(episode.title)")
        .accessibilityIdentifier("\(prefix)-show-notes-\(episode.id)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom, content: content)
    }
}

struct WiltedMacEpisodeNotes<Actions: View>: View {
    let episode: WiltedMacEpisode
    let prefix: String
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme

    static func linkedNotes(for episode: WiltedMacEpisode) -> AttributedString? {
        guard let notes = episode.notes, !notes.isEmpty else { return nil }
        return WiltedShowNotes.linked(notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(episode.title)
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            WiltedMacEpisodeMetadata(episode: episode, identifier: "\(prefix)-notes-metadata-\(episode.id)")
            Divider()
            ScrollView {
                if let notes = Self.linkedNotes(for: episode) {
                    Text(notes)
                        .wiltedFont(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("\(prefix)-notes-text-\(episode.id)")
                } else {
                    Text("This episode's feed did not include show notes.")
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("\(prefix)-notes-unavailable-\(episode.id)")
                }
            }
            .frame(maxHeight: .infinity)
            actions()
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: 420, height: 360)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(prefix)-notes-popover-\(episode.id)")
    }
}

struct WiltedMacLarderEpisodeNotesTitle: View {
    let episode: WiltedMacEpisode
    @State private var isPresented = false

    var body: some View {
        WiltedMacEpisodeNotesTitle(episode: episode, prefix: "wilted-menu", isPresented: $isPresented) {
            WiltedMacEpisodeNotes(episode: episode, prefix: "wilted-menu") { EmptyView() }
        }
    }
}
