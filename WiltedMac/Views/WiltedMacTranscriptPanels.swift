import SwiftUI
import WiltedDomain

/// The transcript of what is playing, shared by the playback rail and the
/// two-pane Now Playing pane so the two cannot draw different transcripts.
struct WiltedMacTranscriptPanel: View {
    @Bindable var model: WiltedMacModel
    /// Fixed height for a host with no viewport of its own (the inline rail);
    /// nil lets the panel fill what it is given.
    var viewportHeight: CGFloat?
    /// Lets the reader scroll away from the active line; nil always follows.
    var following: Binding<Bool>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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
                    identifier: "wilted-now-playing-synced-transcript",
                    following: following
                ) { line in
                    if let cue = transcript.cue(forLineID: line.id) { model.seekToTranscriptCue(cue) }
                    // Picking a line is the reader choosing where "now" is.
                    following?.wrappedValue = true
                }
                .frame(height: viewportHeight)
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
}

/// The feed's show notes for what is playing.
struct WiltedMacNotesPanel: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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
}
