import SwiftUI
import WiltedLibrary

/// Names the exact headline being read and keeps its original article link after speech ends.
struct LibraryNowPlayingHeadlineCard: View {
    @ObservedObject var controller: LibraryInterruptionController
    @Environment(\.colorScheme) private var colorScheme

    private var bulletin: Bulletin? { controller.nowPlayingHeadline }

    var body: some View {
        if let bulletin {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Label(
                    controller.activeSpokenHeadline?.id == bulletin.id ? "Reading this story" : "Last story read",
                    systemImage: controller.activeSpokenHeadline?.id == bulletin.id ? "speaker.wave.2.fill" : "newspaper")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        controller.activeSpokenHeadline?.id == bulletin.id ? "Reading this story" : "Last story read")
                    .accessibilityIdentifier("wilted-player-headline-state")
                Text(bulletin.headline ?? bulletin.text)
                    .wiltedFont(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-player-headline-title")
                if let publisher = bulletin.publisherName, !publisher.isEmpty {
                    Text(publisher)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-player-headline-publisher")
                }
                if let link = bulletin.link {
                    Link("Read story", destination: link)
                        .wiltedFont(.body)
                        .accessibilityIdentifier("wilted-player-headline-read-\(bulletin.headlineStoryID ?? bulletin.id)")
                        .accessibilityValue(link.absoluteString)
                } else {
                    Text("Story link unavailable")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-player-headline-link-unavailable")
                }
            }
            .wiltedCard(colorScheme, padding: WiltedTheme.Spacing.medium)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-player-headline-story-card")
        }
    }
}
