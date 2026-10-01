import SwiftUI
import WiltedDomain
import WiltedLibrary

/// Splits published episode notes into paragraphs: plain text only, blank lines and line breaks
/// both separate paragraphs, and empty paragraphs are dropped.
enum LibraryNotes {
    static func paragraphs(_ notes: String) -> [String] {
        notes.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// The episode detail's transcript section: its `content` when given, else a placeholder.
struct LibraryTranscriptSlot<Content: View>: View {
    let entryID: ItemID
    private let content: Content?
    @Environment(\.colorScheme) private var colorScheme

    init(entryID: ItemID, @ViewBuilder content: () -> Content) {
        self.entryID = entryID
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Transcript").wiltedFont(.title)
            if let content {
                content
            } else {
                Label {
                    Text("Transcript not available yet").wiltedFont(.body)
                } icon: {
                    Image(systemName: "text.alignleft")
                }
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-library-detail-transcript-placeholder")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-detail-transcript")
    }
}

extension LibraryTranscriptSlot where Content == EmptyView {
    /// The reserved, empty slot.
    init(entryID: ItemID) {
        self.entryID = entryID
        self.content = nil
    }
}

/// One episode in full: large artwork, title, show, date, duration, the notes the Mac published,
/// the same audio actions as its Larder row, and the transcript section. Reads the row
/// live from the model, so progress and state keep moving while it is open.
struct LibraryEpisodeDetailView: View {
    @ObservedObject var model: LibraryAppModel
    let entryID: ItemID
    var playingID: ItemID?
    var onPlay: ((LibraryRow) -> Void)?
    /// When given, the transcript follows this player while the episode is its loaded item.
    var player: LibraryPlayer?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let row = model.queued.first(where: { $0.id == entryID }) {
                content(row)
            } else {
                ContentUnavailableView {
                    Label("Episode not in the Larder", systemImage: "questionmark.circle")
                } description: {
                    Text("The Mac no longer lists this episode.")
                }
                .accessibilityIdentifier("wilted-library-detail-missing")
            }
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ row: LibraryRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                LibraryArtwork(url: row.artworkURL, side: 240, isDecorative: false)
                    .accessibilityLabel("Artwork for \(row.title)")
                    .accessibilityIdentifier("wilted-library-detail-artwork")
                    .frame(maxWidth: .infinity)
                header(row)
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                    LibraryEpisodeActions(
                        row: row, media: model.mediaState(for: row.id),
                        isPlaying: playingID == row.id,
                        onMedia: { model.performMediaAction($0, entryID: row.id) },
                        onPlay: onPlay.map { play in { play(row) } },
                        decisionActions: model.decisionActions(for: row),
                        decisionStatus: model.decisionStatus(for: row.id),
                        onDecision: { model.performDecision($0, entryID: row.id) },
                        onCancelDecision: { model.cancelDecision(entryID: row.id) })
                }
                notes(row)
                LibraryTranscriptSlot(entryID: row.id) {
                    LibraryTranscriptSection(model: model, entryID: row.id, player: player, height: 360)
                }
            }
            .padding(WiltedTheme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("wilted-library-detail")
    }

    private func header(_ row: LibraryRow) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text(row.title)
                .wiltedFont(.title)
                .textSelection(.enabled)
                .accessibilityIdentifier("wilted-library-detail-title")
            Text(row.showTitle)
                .wiltedFont(.body)
                .foregroundStyle(secondary)
                .accessibilityIdentifier("wilted-library-detail-show")
            Text(meta(row))
                .wiltedFont(.utility)
                .foregroundStyle(secondary)
                .accessibilityIdentifier("wilted-library-detail-meta")
            if let removal = row.removalText {
                Text(removal)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
            }
            LibraryCheckpointLine(row: row, player: player, identifier: "wilted-library-detail-checkpoint")
        }
    }

    private func notes(_ row: LibraryRow) -> some View {
        let paragraphs = LibraryNotes.paragraphs(row.summary)
        return VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Notes").wiltedFont(.title)
            if paragraphs.isEmpty {
                Text("No notes for this episode.")
                    .wiltedFont(.body)
                    .foregroundStyle(secondary)
            } else {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).wiltedFont(.body).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-detail-notes")
    }

    private func meta(_ row: LibraryRow) -> String {
        [row.durationText, row.publishedAt.formatted(.dateTime.month(.abbreviated).day().year())]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var secondary: Color { WiltedTheme.color(.secondaryText, scheme: colorScheme) }
}
