import SwiftUI
import WiltedDomain
import WiltedLibrary

/// The transcript for one episode. Timed transcripts are a cue list: while `position` is given
/// (the episode is the playing item) the current cue is bold with a leading marker and the list
/// follows it, and tapping a cue calls `onSeek`. Without a position it is a plain cue list.
/// A plain-text transcript is prose. The current cue is never shown by color alone.
struct LibraryTranscriptView: View {
    let transcript: LibraryTranscript
    /// Seconds into the audio when this entry is the playing item; nil otherwise.
    var position: Double?
    /// Seeks the player; nil when this entry is not the playing item.
    var onSeek: ((Double) -> Void)?
    /// Fixed height for a list inside another scroll view; nil fills the space it is given.
    var height: CGFloat?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false
    @State private var lastTouch: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            if transcript.isTimed {
                cueList
            } else if let text = transcript.plainText {
                prose(text)
            }
            if transcript.isTruncated {
                Label("This transcript is shortened.", systemImage: "scissors")
                    .wiltedFont(.utility)
                    .foregroundStyle(secondary)
                    .accessibilityIdentifier("wilted-library-transcript-truncated")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-transcript")
    }

    private var current: Int? { LibraryTranscriptFollow.currentIndex(in: transcript.cues, at: position) }

    private var cueList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                    ForEach(Array(transcript.cues.enumerated()), id: \.offset) { index, cue in
                        cueRow(index: index, cue: cue, isCurrent: index == current)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: height)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        isDragging = true
                        lastTouch = Date()
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastTouch = Date()
                    })
            .onChange(of: current) { _, index in
                guard let index,
                      LibraryTranscriptFollow.shouldAutoScroll(isDragging: isDragging, lastTouch: lastTouch, now: Date())
                else { return }
                withAnimation { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func cueRow(index: Int, cue: LibraryTranscriptCue, isCurrent: Bool) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.small) {
            Image(systemName: "play.fill")
                .imageScale(.small)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(LibraryTranscriptFollow.timecode(cue.start))
                .wiltedFont(.utility)
                .monospacedDigit()
                .foregroundStyle(secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = cue.speaker {
                    Text(speaker)
                        .wiltedFont(.utility)
                        .fontWeight(.semibold)
                        .foregroundStyle(secondary)
                        .accessibilityIdentifier("wilted-library-transcript-speaker-\(index)")
                }
                Text(cue.text)
                    .wiltedFont(.body)
                    .fontWeight(isCurrent ? .bold : .regular)
                    .foregroundStyle(isCurrent ? WiltedTheme.color(.progress, scheme: colorScheme) : primary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: onSeek == nil ? 0 : WiltedTheme.Spacing.minimumTouchTarget, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCurrent ? "Current" : "")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("wilted-library-transcript-cue-\(index)")
        if let target = LibraryTranscriptFollow.seekTarget(for: cue, isPlayingItem: onSeek != nil), let onSeek {
            Button { onSeek(target) } label: { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("Plays from here")
        } else {
            row
        }
    }

    @ViewBuilder
    private func prose(_ text: String) -> some View {
        if height == nil {
            ScrollView { proseText(text) }
        } else {
            proseText(text)
        }
    }

    private func proseText(_ text: String) -> some View {
        Text(text)
            .wiltedFont(.body)
            .foregroundStyle(primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("wilted-library-transcript-text")
    }

    private var primary: Color { WiltedTheme.color(.primaryText, scheme: colorScheme) }
    private var secondary: Color { WiltedTheme.color(.secondaryText, scheme: colorScheme) }
}

/// The transcript for `entryID` as the detail screen and the full player show it: loads it when
/// shown, follows the player when this entry is the loaded item, and says why when there is none.
struct LibraryTranscriptSection: View {
    @ObservedObject var model: LibraryAppModel
    let entryID: ItemID
    var player: LibraryPlayer?
    var height: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let transcript = model.transcript(for: entryID) {
                if let player {
                    Bound(transcript: transcript, entryID: entryID, player: player, height: height)
                } else {
                    LibraryTranscriptView(transcript: transcript, height: height)
                }
            } else {
                Label {
                    Text(model.mediaState(for: entryID) == .onPhone
                        ? "Transcript not available yet" : "Get the audio to see its transcript")
                        .wiltedFont(.body)
                } icon: {
                    Image(systemName: "text.alignleft")
                }
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-library-detail-transcript-placeholder")
            }
        }
        .task(id: model.media[entryID] == .onPhone) {
            await model.prepareTranscript(entryID: entryID)
            // The Mac may publish it later; look again each interval while this screen stays open.
            while !Task.isCancelled, model.media[entryID] == .onPhone, model.transcript(for: entryID) == nil {
                try? await Task.sleep(for: .seconds(LibraryAppModel.transcriptRetryInterval))
                if Task.isCancelled { return }
                await model.prepareTranscript(entryID: entryID)
            }
        }
    }

    /// Observes the player so only the transcript, not the whole screen, redraws with its position.
    private struct Bound: View {
        let transcript: LibraryTranscript
        let entryID: ItemID
        @ObservedObject var player: LibraryPlayer
        var height: CGFloat?

        var body: some View {
            let isPlayingItem = player.item?.entryID == entryID
            LibraryTranscriptView(
                transcript: transcript,
                position: isPlayingItem ? player.position : nil,
                onSeek: isPlayingItem ? { player.seek(to: $0) } : nil,
                height: height)
        }
    }
}
