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
            HStack(spacing: WiltedTheme.Spacing.small) {
                Text(model.playbackStatusMessage)
                    .wiltedFont(.utility)
                    .foregroundStyle(model.playbackStatusTone.color(colorScheme))
                    .accessibilityIdentifier("wilted-player-status")
                WiltedMacPlaybackRetryButton(model: model)
            }
        }
    }

    /// Idle until a command is issued: a pending start or its failure answers
    /// the press here, outside the idle element so its label stays stable.
    var minimizedIdlePlayer: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            minimizedIdleSummary
            WiltedMacPlaybackStartResult(model: model)
        }
    }

    private var minimizedIdleSummary: some View {
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

/// The answer to the newest playback command while nothing is current: the
/// pending start, or why it failed, with a retry when retrying can help.
struct WiltedMacPlaybackStartResult: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if model.showsPlaybackCommandResult {
            HStack(spacing: WiltedTheme.Spacing.small) {
                if model.playbackCommands.pending != nil {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text(model.playbackStatusMessage)
                    .wiltedFont(.utility)
                    .foregroundStyle(model.playbackStatusTone.color(colorScheme))
                    .accessibilityIdentifier("wilted-player-start-result")
                WiltedMacPlaybackRetryButton(model: model)
            }
        }
    }
}

/// Retry for a refused start only. A route fault keeps its own Recover
/// audio control, so one fault never shows two buttons.
struct WiltedMacPlaybackRetryButton: View {
    let model: WiltedMacModel

    var body: some View {
        if model.canRetryPlayback {
            Button("Retry playback") { model.retryPlayback() }
                .accessibilityIdentifier("wilted-player-retry-playback")
        }
    }
}

/// The speed picker's own save line, scoped to the loaded episode. A save
/// never writes any other status, and a failure says which speed applies now
/// and which one a restart would use.
struct WiltedMacSpeedSaveLine: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let status = model.currentSpeedSaveStatus, status.phase != .saved {
            HStack(spacing: WiltedTheme.Spacing.small) {
                Text(status.message)
                    .wiltedFont(.utility)
                    .foregroundStyle((status.phase == .failed ? WiltedStatusTone.failure : .neutral).color(colorScheme))
                    .accessibilityIdentifier("wilted-player-speed-save-status")
                if status.phase == .failed {
                    Button("Retry speed save") { model.retrySpeedSave() }
                        .accessibilityIdentifier("wilted-player-speed-save-retry")
                }
            }
        }
    }
}
