import AppKit
import SwiftUI
import WiltedDomain

extension WiltedMacPlayerContent {
    @ViewBuilder
    var playbackStatus: some View {
        // The play/pause transport already speaks these two states. Do not
        // create a second visible or accessible status row for them.
        if model.playbackStatusMessage != "Playing",
           model.playbackStatusMessage != "Paused" {
            Text(model.playbackStatusMessage)
                .wiltedFont(.utility)
                .foregroundStyle(model.playbackStatusTone.color(colorScheme))
                .accessibilityIdentifier("wilted-player-status")
        }
    }

    var minimizedIdlePlayer: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Image(systemName: "play.circle")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing is playing")
                    .wiltedFont(.body)
                Text("Choose an episode or article from Larder to start playback.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Minimized")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nothing is playing")
        .accessibilityValue("Minimized")
        .accessibilityIdentifier("wilted-player-idle")
    }

    @ViewBuilder
    func expandedContent(_ target: WiltedMacPlayerSection) -> some View {
        switch target {
        case .transcript:
            transcriptContent
                .accessibilityIdentifier(target.expandedAccessibilityIdentifier)
        case .notes:
            notesContent
                .accessibilityIdentifier(target.expandedAccessibilityIdentifier)
        }
    }

    private var transcriptContent: some View {
        WiltedMacTranscriptPanel(model: model, viewportHeight: layout.synchronizedTranscriptViewportHeight)
    }

    private var notesContent: some View {
        WiltedMacNotesPanel(model: model)
    }

    @ViewBuilder
    var artwork: some View {
        if let url = model.currentEpisode?.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallbackArtwork
            }
            .wiltedSquare(44)
            .clipped()
        } else {
            fallbackArtwork
        }
    }

    private var fallbackArtwork: some View {
        WiltedProduceTile(symbol: model.currentEpisode == nil ? .lettuce : .cabbage, size: 44)
            .accessibilityLabel("Playback artwork unavailable")
    }

    var title: String {
        model.currentEpisode?.title ?? model.currentArticle?.title ?? "Nothing is playing"
    }

    var detail: String {
        if let episode = model.currentEpisode {
            return "\(episode.feedTitle) · \(episode.releasedAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return model.currentArticle?.source ?? WiltedScreenCopy.nowPlayingEmptyDetailProducer
    }

    func collapsePresentation() {
        guard let presentation else { return }
        if layout == .fullWindow {
            onCollapse(presentation)
        } else {
            self.presentation = nil
        }
    }

    func transport(
        _ symbol: String,
        label: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .wiltedSquare(28)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
