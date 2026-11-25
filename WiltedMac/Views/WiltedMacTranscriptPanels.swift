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
    private var search: WiltedMacTranscriptSearch { model.currentTranscriptSearch }
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let transcript = model.currentTranscript ?? .unavailable
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            if model.hasCurrentPlayback { searchControls(transcript) }
            Group {
                // A synchronised transcript owns its own scrolling: it has to move the
                // active line to the middle as the audio advances, which a parent
                // scroll view would fight.
                if model.hasCurrentPlayback, transcript.isSynchronized {
                    let allCues = transcript.cues.map {
                        WiltedTranscriptCueLine(id: $0.id, startSeconds: $0.startSeconds,
                                                text: $0.text, speaker: $0.speaker)
                    }
                    let matches = search.matchingLineIndices(in: allCues.map(\.text))
                    let displayedCues = search.trimmedQuery.isEmpty
                        ? allCues : matches.map { allCues[$0] }
                    let selectedCue = selectedCue(in: displayedCues)
                    WiltedSyncedTranscriptView(
                        cues: displayedCues,
                        markers: search.trimmedQuery.isEmpty ? model.currentRemovedSpans.map {
                            WiltedTranscriptMarkerLine(id: $0.id, atSeconds: $0.preparedSeconds, text: $0.summary)
                        } : [],
                        activeCueID: model.activeTranscriptCueID,
                        selectedCueID: selectedCue?.id,
                        highlightQuery: search.trimmedQuery.isEmpty ? nil : search.trimmedQuery,
                        identifier: "wilted-now-playing-synced-transcript",
                        following: following
                    ) { line in
                        if let index = displayedCues.firstIndex(where: { $0.id == line.id }) {
                            updateSearch { $0.select(index, matchCount: displayedCues.count) }
                        }
                        if let cue = transcript.cue(forLineID: line.id) { model.seekToTranscriptCue(cue) }
                        // Picking a line is the reader choosing where "now" is.
                        following?.wrappedValue = true
                    }
                    .frame(height: viewportHeight)
                } else {
                    unsyncedTranscriptContent(transcript)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("wilted-now-playing-transcript")
        .onChange(of: model.currentEpisode?.id) { _, _ in updateSearch { $0.setQuery("") } }
    }

    private func searchControls(_ transcript: WiltedMacTranscript) -> some View {
        let lines = searchableLines(in: transcript)
        let matches = search.matchingLineIndices(in: lines)

        return HStack(spacing: WiltedTheme.Spacing.small) {
            TextField("Search transcript", text: Binding(
                get: { search.query },
                set: { query in updateSearch { $0.setQuery(query) } }
            ))
            .textFieldStyle(.roundedBorder)
            .disabled(!transcript.isReadable)
            .accessibilityIdentifier("wilted-now-playing-transcript-search")

            if !search.trimmedQuery.isEmpty, transcript.isReadable {
                Text(matches.isEmpty ? "No matches" : "\(search.selectionIndex(matchCount: matches.count) + 1) of \(matches.count) matches")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
                    .accessibilityIdentifier("wilted-now-playing-transcript-search-count")
                Button {
                    moveSearchSelection(previous: true, transcript: transcript)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous match")
                .accessibilityLabel("Previous match")
                .accessibilityIdentifier("wilted-now-playing-transcript-search-previous")
                .disabled(matches.count < 2)
                Button {
                    moveSearchSelection(previous: false, transcript: transcript)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Next match")
                .accessibilityLabel("Next match")
                .accessibilityIdentifier("wilted-now-playing-transcript-search-next")
                .disabled(matches.count < 2)
            }
        }
    }

    private func searchableLines(in transcript: WiltedMacTranscript) -> [String] {
        search.lines(in: transcript)
    }

    private func selectedCue(in displayedCues: [WiltedTranscriptCueLine]) -> WiltedTranscriptCueLine? {
        guard !search.trimmedQuery.isEmpty, !displayedCues.isEmpty else { return nil }
        let index = search.selectionIndex(matchCount: displayedCues.count)
        return displayedCues[index]
    }

    private func moveSearchSelection(previous: Bool, transcript: WiltedMacTranscript) {
        let lines = searchableLines(in: transcript)
        let matches = search.matchingLineIndices(in: lines)
        guard !matches.isEmpty else { return }
        updateSearch {
            if previous { $0.selectPrevious(matchCount: matches.count) }
            else { $0.selectNext(matchCount: matches.count) }
        }

        let selectedIndex = search.selectionIndex(matchCount: matches.count)
        guard transcript.isSynchronized, transcript.cues.indices.contains(matches[selectedIndex]) else { return }
        model.seekToTranscriptCue(transcript.cues[matches[selectedIndex]])
        following?.wrappedValue = true
    }

    private func updateSearch(_ update: (inout WiltedMacTranscriptSearch) -> Void) {
        var value = model.currentTranscriptSearch
        update(&value)
        model.currentTranscriptSearch = value
    }

    private func unsyncedTranscriptContent(_ transcript: WiltedMacTranscript) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                if !model.hasCurrentPlayback {
                    Text(WiltedScreenCopy.nowPlayingEmptyDetailProducer)
                        .wiltedFont(.body)
                } else {
                    Group {
                        if transcript.isReadable, let text = transcript.text {
                            if search.trimmedQuery.isEmpty {
                                Text(text)
                                    .wiltedFont(.body)
                                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                let lines = searchableLines(in: transcript)
                                let matches = search.matchingLineIndices(in: lines)
                                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                                    ForEach(matches, id: \.self) { lineIndex in
                                        let resultIndex = matches.firstIndex(of: lineIndex) ?? 0
                                        WiltedTranscriptTextHighlight.text(
                                            lines[lineIndex], query: search.trimmedQuery, scheme: colorScheme
                                        )
                                        .wiltedFont(.body)
                                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.vertical, 2)
                                        .padding(.horizontal, WiltedTheme.Spacing.small)
                                        .background(
                                            RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
                                                .fill(resultIndex == search.selectionIndex(matchCount: matches.count)
                                                      ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.18)
                                                      : Color.clear)
                                        )
                                        .accessibilityIdentifier("wilted-now-playing-transcript-search-result-\(lineIndex)")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else if transcript.availability == .loading {
                            HStack(spacing: WiltedTheme.Spacing.small) {
                                ProgressView().controlSize(.small)
                                Text("Loading transcript…")
                                    .wiltedFont(.utility)
                                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            }
                        } else if transcript.availability == .failed {
                            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                                Text("Could not read the saved transcript.")
                                    .wiltedFont(.utility)
                                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Retry") {
                                    model.retryCurrentTranscriptLoad()
                                }
                                .accessibilityIdentifier("wilted-now-playing-transcript-retry")
                            }
                        } else {
                            Label(
                                model.currentEpisode == nil ? transcript.unavailableLabel
                                    : "Transcript unavailable. Prepare this episode to add one.",
                                systemImage: "doc.text.magnifyingglass")
                                .wiltedFont(.utility)
                                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        }
                    }
                    .accessibilityIdentifier("wilted-now-playing-transcript-body")
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
                    if !transcript.isReadable, transcript.availability != .loading, model.currentEpisode == nil {
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
                if let notes = model.currentEpisode.flatMap(WiltedMacEpisodeNotes<EmptyView>.linkedNotes(for:)) {
                    Text(notes)
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
