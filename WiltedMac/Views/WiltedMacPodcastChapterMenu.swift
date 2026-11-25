import SwiftUI

/// Lets listeners jump directly to a podcast chapter from the shared player.
struct WiltedMacPodcastChapterMenu: View {
    @Bindable var model: WiltedMacModel

    var body: some View {
        Menu {
            ForEach(Array((model.currentEpisode?.podcastChapters ?? []).enumerated()), id: \.offset) { item in
                Button {
                    model.selectPodcastChapter(at: item.offset)
                } label: {
                    Text(item.element.title)
                }
                .accessibilityIdentifier("wilted-player-chapter-option-\(item.offset)")
            }
        } label: {
            Label("Chapters", systemImage: "list.bullet")
        }
        .accessibilityIdentifier("wilted-player-chapter-list")
    }
}
