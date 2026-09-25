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

    @ViewBuilder private var transcriptContent: some View {
        let transcript = model.currentTranscript ?? .unavailable
        // A synchronised transcript owns its own scrolling: it has to move the
        // active line to the middle as the audio advances, which a parent
        // scroll view would fight.
        if model.hasCurrentPlayback, transcript.isSynchronized {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Text(transcript.disclosureTitle)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-now-playing-transcript")
                WiltedSyncedTranscriptView(
                    cues: transcript.cues.map {
                        WiltedTranscriptCueLine(id: $0.id, startSeconds: $0.startSeconds, text: $0.text, speaker: $0.speaker)
                    },
                    markers: model.currentRemovedSpans.map {
                        WiltedTranscriptMarkerLine(id: $0.id, atSeconds: $0.preparedSeconds, text: $0.summary)
                    },
                    activeCueID: model.activeTranscriptCueID,
                    identifier: "wilted-now-playing-synced-transcript"
                ) { model.seekToTranscriptCue(transcript.cues[$0.id]) }
                .frame(height: layout.synchronizedTranscriptViewportHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            unsyncedTranscriptContent(transcript)
        }
    }

    private func unsyncedTranscriptContent(_ transcript: WiltedMacTranscript) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                if !model.hasCurrentPlayback {
                    Text(WiltedScreenCopy.nowPlayingEmptyDetailProducer)
                        .wiltedFont(.body)
                } else {
                    WiltedTranscriptSection(
                        isReadable: transcript.isReadable,
                        title: transcript.disclosureTitle,
                        text: transcript.text,
                        unavailableLabel: model.currentEpisode == nil
                            ? transcript.unavailableLabel
                            : "Transcript unavailable. Prepare this episode to add one.",
                        identifier: "wilted-now-playing-transcript"
                    )
                    // Untimed prose has nowhere to put a marker in place, so
                    // the cuts are listed instead of dropped silently.
                    if !model.currentRemovedSpans.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.currentRemovedSpans) { span in
                                Text(span.summary)
                                    .wiltedFont(.utility)
                                    .italic()
                                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                    .accessibilityIdentifier("wilted-now-playing-removed-\(span.id)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("wilted-now-playing-removed-spans")
                    }
                    // Backfill fetches article text from the web; an episode's
                    // transcript comes from preparation instead.
                    if !transcript.isReadable, model.currentEpisode == nil {
                        Button(model.isBackfillingTranscript ? "Fetching transcript…" : "Fetch transcript") {
                            model.backfillCurrentTranscript()
                        }
                        .disabled(model.isBackfillingTranscript)
                        .accessibilityIdentifier("wilted-now-playing-fetch-transcript")
                    }
                    if let status = model.transcriptBackfillStatus {
                        Text(status)
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("wilted-now-playing-transcript-status")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Text("Show Notes")
                    .wiltedFont(.title)
                if let notes = model.currentEpisode?.notes {
                    Text(WiltedShowNotes.linked(notes))
                        .wiltedFont(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-player-notes-text")
                } else {
                    Text("This episode's feed did not include show notes.")
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-player-notes-unavailable")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-player-notes-list")
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
