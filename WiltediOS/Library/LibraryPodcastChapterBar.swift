import SwiftUI
import WiltedDomain

/// Podcast chapters arrive in the Mac's prepared-clock payload and seek the same cached file as audiobook controls.
struct LibraryPodcastChapterBar: View {
    @ObservedObject var player: LibraryPlayer
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let title = player.currentPodcastChapterTitle,
           let chapters = player.item?.podcastChapters,
           let currentIndex = player.currentPodcastChapterIndex {
            VStack(spacing: WiltedTheme.Spacing.xSmall) {
                Text(title)
                    .wiltedFont(.body)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("wilted-player-chapter-title")
                Text("Chapter \(currentIndex + 1) of \(chapters.count)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-player-chapter-position")
                HStack(spacing: WiltedTheme.Spacing.section) {
                    Button { player.selectPreviousPodcastChapter() } label: {
                        Image(systemName: "backward.end")
                    }
                    .disabled(!player.canSelectPreviousPodcastChapter)
                    .accessibilityLabel("Previous chapter")
                    .accessibilityIdentifier("wilted-player-previous-chapter")
                    Menu {
                        ForEach(Array(chapters.enumerated()), id: \.offset) { item in
                            Button { player.selectPodcastChapter(at: item.offset) } label: {
                                HStack {
                                    Text(item.element.title)
                                    if item.offset == currentIndex { Image(systemName: "checkmark") }
                                }
                            }
                            .accessibilityIdentifier("wilted-player-chapter-option-\(item.offset)")
                        }
                    } label: {
                        Label("Chapters", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier("wilted-player-chapter-list")
                    Button { player.selectNextPodcastChapter() } label: {
                        Image(systemName: "forward.end")
                    }
                    .disabled(!player.canSelectNextPodcastChapter)
                    .accessibilityLabel("Next chapter")
                    .accessibilityIdentifier("wilted-player-next-chapter")
                }
                .buttonStyle(LibraryPlayerButtonStyle())
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-player-chapters")
        }
    }
}
